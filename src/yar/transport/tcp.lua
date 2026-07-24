-- yar/transport/tcp.lua
-- TCP 传输：通过 TCP 连接发送 YAR 消息（连 yar-c 风格 TCP Server）。
-- 依赖 transport.socket 抽象，框架本身不引用 ngx。

local Socket  = require("yar.transport.socket")
local Framing = require("yar.protocol.framing")
local Resolve = require("yar.transport.resolve")
local Const   = require("yar.transport.constants")

local string, tonumber, setmetatable = string, tonumber, setmetatable

---@class Tcp
---@field options table|nil Client options
---@field transport_opts table|nil Transport-specific options
---@field host string|nil Connected host
---@field port number|nil Connected port
---@field unix_path string|nil Unix socket path
---@field sock table|nil Cached persistent socket
local _M = {}
_M.__index = _M

--- Create a new TCP transport instance
---@return Tcp
function _M.new()
    return setmetatable({}, _M)
end

--- Open a connection to the given URL
---@param url string tcp://host:port or unix:///path/to/socket
---@param options table|nil Transport options
---@return boolean|nil ok true on success, nil on failure
---@return string|nil err Error message on failure
function _M:open(url, options)
    -- url 形如 tcp://host:port 或 unix:///path/to/socket
    self.options = options or {}
    self.transport_opts = options.transport or options
    local unix_path = string.match(url, "^unix://(.+)")
    if unix_path then
        self.unix_path = unix_path
    else
        local host, port = string.match(url, "^tcp://([^:]+):(%d+)")
        if not host or not port then
            return nil, "invalid tcp url: " .. url
        end
        self.host = host
        self.port = tonumber(port)
    end
    return true
end

--- Send data over the TCP connection and receive response
---@param data string YAR binary message to send
---@return string|nil resp Received YAR binary response message
---@return string|nil err Error message
function _M:send(data)
    local max_body_len = self.transport_opts.max_body_len
    -- 持久连接复用：若已有缓存的 socket，直接尝试发送
    if self.sock then
        if max_body_len then
            local ok, err = Framing.check_body_len(data, max_body_len)
            if not ok then return nil, err end
        end
        local sent, serr = self.sock:send(data)
        if not serr then
            -- 发送成功，尝试接收响应
            local resp, rerr = Framing.receive_message(self.sock, max_body_len)
            if resp then return resp end
            -- 接收失败：服务端可能已处理请求，不可重发，直接返回错误
            self.sock:close()
            self.sock = nil
            return nil, rerr or "connection lost during receive"
        end
        -- 发送失败：关闭旧连接
        self.sock:close()
        self.sock = nil
        -- cosocket send 失败时返回 nil, err（0 字节发出，安全重试）
        -- luasocket send 失败时返回已发送字节数, err（>0 则服务端可能已收到部分数据，不可重试）
        if sent and sent > 0 then
            return nil, "partial send (" .. sent .. " bytes), connection broken mid-flight"
        end
        -- sent 为 nil 或 0：数据未到达服务端，安全走新建逻辑
    end

    -- 创建新连接：unix socket 用 Socket.unix()，TCP 用 Socket.tcp()
    local sock, err
    if self.unix_path then
        sock, err = Socket.unix()
    else
        sock, err = Socket.tcp()
    end
    if not sock then return nil, err end
    -- 超时：cosocket 三段（connect/send/receive），luasocket 单一
    local timeout = self.transport_opts.timeout or Const.DEFAULT_TIMEOUT
    local connect_timeout = self.transport_opts.connect_timeout or Const.DEFAULT_CONNECT_TIMEOUT
    Socket.set_timeouts(sock, connect_timeout, timeout, timeout)

    local ok, cerr
    if self.unix_path then
        ok, cerr = sock:connect(self.unix_path)
    else
        local connect_host = Resolve.apply_resolve(self.host, self.port, self.transport_opts.resolve)
        ok, cerr = sock:connect(connect_host, self.port)
    end
    if not ok then sock:close(); return nil, cerr end

    if max_body_len then
        local blen_ok, blen_err = Framing.check_body_len(data, max_body_len)
        if not blen_ok then sock:close(); return nil, blen_err end
    end
    local _, serr2 = sock:send(data)
    if serr2 then sock:close(); return nil, serr2 end
    local resp, rerr = Framing.receive_message(sock, max_body_len)

    -- receive 失败：socket 可能含残留数据或已断开，不可缓存/复用
    if not resp then
        sock:close()
        return nil, rerr
    end

    -- persistent 模式：缓存 socket 跨 call 复用；否则归还连接池/关闭
    if self.transport_opts.persistent then
        self.sock = sock
    else
        local ka = self.transport_opts.keepalive or {}
        Socket.release(sock, ka.idle_timeout, ka.pool_size)
    end

    return resp
end

--- Close the persistent cached connection (cosocket returns to pool, luasocket closes)
function _M:close()
    -- persistent 模式下关闭缓存的持久连接（cosocket 归池，luasocket close）
    if self.sock then
        local ka = self.transport_opts.keepalive or {}
        Socket.release(self.sock, ka.idle_timeout, ka.pool_size)
        self.sock = nil
    end
end

return _M
