-- yar/transport/socket.lua
-- Socket 提供者：传输层唯一的网络抽象。框架不直接引用 ngx，只依赖此抽象。
-- 默认适配 luasocket（纯 Lua），超时统一为毫秒，与 OpenResty cosocket 一致。
-- OpenResty 注入 cosocket：  Yar.client.set_socket(ngx.socket)

local pcall = pcall
local ok, socket = pcall(require, "socket")
if not ok then socket = nil end

-- 局部常量（错误消息字符串，避免重复硬编码）
local ERR_LUASOCKET   = "luasocket not available"
local ERR_UNIX_AVAIL  = "unix socket not available (need luasocket with unix support)"
local ERR_CREATE_UNIX = "create unix socket failed"

---@class SocketProvider
---@field tcp function TCP socket factory
---@field unix function|nil Unix socket factory
---@field bind function|nil Server socket factory
---@field setkeepalive function|nil Pool return (cosocket only)
local _M = {}

-- 将 luasocket 对象包装为「毫秒超时 + cosocket 方法名」契约
local function wrap(s)
    return {
        -- nil = 阻塞模式（luasocket 语义），正数 = 超时毫秒
        settimeout = function(_, ms)
            if ms == nil then return s:settimeout(nil) end
            return s:settimeout(ms / 1000)
        end,
        connect    = function(_, ...) return s:connect(...) end,
        send       = function(_, ...) return s:send(...) end,
        receive    = function(_, ...) return s:receive(...) end,
        close      = function(_, ...) return s:close(...) end,
    }
end

-- 将 luasocket server socket 包装为统一接口
-- accept 返回的 client socket 也需要 wrap（与 tcp()/unix() 返回的一致）
local function wrap_server(s)
    return {
        accept = function()
            local client, err = s:accept()
            if not client then return nil, err end
            return wrap(client)
        end,
        -- nil = 阻塞模式（luasocket 语义），正数 = 超时毫秒
        settimeout = function(_, ms)
            if ms == nil then return s:settimeout(nil) end
            return s:settimeout(ms / 1000)
        end,
        close      = function(_, ...) return s:close(...) end,
    }
end

-- Unix socket 模块（luasocket 可选扩展，需编译时包含）
local ok_unix, unix_mod = pcall(require, "socket.unix")
if not ok_unix then unix_mod = nil end

local default = {
    tcp = function()
        if not socket then return nil, ERR_LUASOCKET end
        local s = socket.tcp()
        if not s then return nil, "create socket failed" end
        return wrap(s)
    end,
    -- 创建 Unix domain socket（AF_UNIX 流式）
    -- cosocket 无独立 unix 类型，注入时 provider.unix() 应返回 cosocket tcp
    -- 对象 + connect 包装翻译 path → "unix:"..path
    unix = function()
        if not unix_mod then return nil, ERR_UNIX_AVAIL end
        local s = unix_mod()
        if not s then return nil, ERR_CREATE_UNIX end
        return wrap(s)
    end,
    -- 创建监听 socket（server 端用）
    -- cosocket provider 可不提供 bind（OpenResty 环境不走 run() 路径）
    bind = function(host, port)
        if not socket then return nil, ERR_LUASOCKET end
        local s = socket.bind(host, port)
        if not s then return nil, "bind failed" end
        return wrap_server(s)
    end,
    -- 创建 Unix domain socket 监听（server 端用）
    bind_unix = function(path)
        if not unix_mod then return nil, ERR_UNIX_AVAIL end
        local s = unix_mod()
        if not s then return nil, ERR_CREATE_UNIX end
        -- luasocket unix socket: bind to path
        local bind_ok, berr = s:bind(path)
        if not bind_ok then s:close(); return nil, "bind failed: " .. tostring(berr) end
        local listen_ok, listen_err = s:listen()
        if not listen_ok then s:close(); return nil, "listen failed: " .. tostring(listen_err) end
        return wrap_server(s)
    end,
}

local provider = default

--- Set socket provider (inject cosocket or other custom implementation)
---@param mod table|nil Socket provider module (nil to reset to default)
function _M.set(mod) provider = mod or default end

--- Create a TCP socket (using current provider)
---@return table|nil socket
---@return string|nil err error message
function _M.tcp() return provider.tcp() end

--- Create a Unix domain socket (using current provider)
---@return table|nil socket
---@return string|nil err error message
function _M.unix() return provider.unix() end

--- Create a listening socket (server-side, using current provider)
-- Default provider uses luasocket's socket.bind; cosocket provider may not provide bind.
---@param host string Listen address
---@param port number Listen port
---@return table|nil server_socket
---@return string|nil err error message
function _M.bind(host, port)
    if not provider.bind then return nil, "current socket provider does not support bind" end
    return provider.bind(host, port)
end

--- Create a Unix domain socket listening socket (server-side, using current provider)
---@param path string Unix socket file path
---@return table|nil server_socket
---@return string|nil err error message
function _M.bind_unix(path)
    if not provider.bind_unix then return nil, "current socket provider does not support bind_unix" end
    return provider.bind_unix(path)
end

--- Set timeouts (compatible with luasocket and cosocket)
-- cosocket supports three-segment timeouts (connect/send/receive), luasocket only supports single timeout.
-- Duck-type detection: if settimeouts method exists, use three-segment; otherwise degrade to settimeout single.
---@param sock table luasocket wrapper object or cosocket
---@param connect_t number Connect timeout (ms)
---@param send_t number Send timeout (ms)
---@param read_t number Read timeout (ms)
function _M.set_timeouts(sock, connect_t, send_t, read_t)
    if sock.settimeouts then
        sock:settimeouts(connect_t, send_t, read_t)
    elseif sock.settimeout then
        sock:settimeout(read_t)
    end
end

--- Release connection (compatible with luasocket and cosocket)
-- cosocket returns to connection pool (setkeepalive), luasocket closes directly.
-- Duck-type detection: if setkeepalive method exists, return to pool; otherwise close.
-- vararg passthrough: cosocket setkeepalive(max_idle, pool_size) parameters assembled by caller.
---@param sock table luasocket wrapper object or cosocket
---@param ... any cosocket setkeepalive parameters (idle_timeout, pool_size)
function _M.release(sock, ...)
    if sock.setkeepalive then
        return sock:setkeepalive(...)
    else
        return sock:close()
    end
end

--- Check if connection pool reuse is supported (compatible with luasocket and cosocket)
-- cosocket has setkeepalive method, supports pool return; luasocket does not, connections are closed after use.
-- Used to decide Connection header default: poolable → keep-alive, otherwise close.
---@param sock table luasocket wrapper object or cosocket
---@return boolean cosocket returns true, luasocket returns false
function _M.poolable(sock)
    return sock.setkeepalive ~= nil
end

return _M
