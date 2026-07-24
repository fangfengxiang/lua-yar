-- yar/client.lua
-- Yar 客户端：构造请求、发送、解析响应

local Request   = require("yar.message.request")
local Response  = require("yar.message.response")
local Protocol  = require("yar.protocol.protocol")
local Packager  = require("yar.packager.packager")
local Transport = require("yar.transport.transport")
local Socket    = require("yar.transport.socket")
local Const     = require("yar.transport.constants")
local Error     = require("yar.error")
local Log       = require("yar.log")

local type, tostring, pcall, pairs, setmetatable, string, getmetatable =
    type, tostring, pcall, pairs, setmetatable, string, getmetatable

--- Run hook under pcall protection; hook errors degrade to Log.warn, not affecting main flow
---@param hook function|nil Hook function
---@param ... any Hook arguments
local function run_hook(hook, ...)
    if not hook then return end
    local ok, err = pcall(hook, ...)
    if not ok then
        Log.warn("hook error: " .. tostring(err))
    end
end

---@class Client
---@field uri string Service address (e.g. "http://host/api", "tcp://host:port")
---@field options table Client options (deep-copied DEFAULT_OPTIONS)
---@field _transport table|nil Cached transport instance (persistent mode)
local _M = {}
_M.__index = _M

-- 嵌套选项结构：protocol（协议层）、transport（传输层）
-- keepalive 子组映射 cosocket setkeepalive(max_idle, pool_size) 参数
local DEFAULT_OPTIONS = {
    protocol = {
        packager = Packager.JSON,
        provider = "",
        token    = "",
    },
    transport = {
        timeout         = Const.DEFAULT_TIMEOUT,
        connect_timeout = Const.DEFAULT_CONNECT_TIMEOUT,
        persistent      = false,
        headers          = {},
        proxy            = "",     -- HTTP 代理地址（对齐 PHP YAR_OPT_PROXY）
        resolve          = "",     -- 自定义 DNS 解析（对齐 PHP YAR_OPT_RESOLVE）
        max_body_len     = nil,    -- 最大 body 长度（默认 nil = Framing.DEFAULT_MAX_BODY_LEN）
        http_provider    = nil,    -- HTTP 传输委托函数（实例级，覆盖类级）
        ssl_verify       = true,   -- HTTPS 证书验证（生产环境必须开启，对齐 lua-resty-http / luasec 默认）
        keepalive        = {
            pool_size     = 64,    -- cosocket 连接池大小
            idle_timeout  = 60000, -- cosocket 空闲超时（ms）
        },
    },
    hooks = { on_request = nil, on_response = nil },  -- 默认空 hooks（自文档化：显式列出两个回调点）
}

-- 扁平 key → 嵌套组路由表（向后兼容 setopt("timeout", 3000) 风格）
local FLAT_KEY_MAP = {
    packager        = "protocol",
    provider        = "protocol",
    token           = "protocol",
    timeout         = "transport",
    connect_timeout = "transport",
    persistent      = "transport",
    headers         = "transport",
    keepalive       = "transport",
    proxy           = "transport",
    resolve         = "transport",
    max_body_len    = "transport",
    http_provider   = "transport",
    ssl_verify      = "transport",
}

--- Recursive deep copy: copies all table levels, no shared references;
-- preserves metatable; prevents circular references
---@param t table Table to copy
---@param seen table|nil Memoization table for circular reference prevention
---@return table Deep copy of t
local function deep_copy(t, seen)
    seen = seen or {}
    if seen[t] then return seen[t] end
    local copy = setmetatable({}, getmetatable(t))
    seen[t] = copy
    for k, v in pairs(t) do
        if type(v) == "table" then
            copy[k] = deep_copy(v, seen)
        else
            copy[k] = v
        end
    end
    return copy
end

--- Kong-style recursive merge: pure structural merge, no per-key special handling
-- References Kong's kong.tools.table.merge: table keys merge recursively, non-table keys overwrite directly
-- Depth limit prevents infinite recursion from circular references
---@param target table Target table (mutated in place)
---@param source table Source table
---@param depth number|nil Current recursion depth (default 0)
---@return table Merged target table
local function deep_merge(target, source, depth)
    depth = depth or 0
    if depth > 100 then return target end
    for k, v in pairs(source) do
        if type(v) == "table" and type(target[k]) == "table" then
            deep_merge(target[k], v, depth + 1)
        else
            target[k] = v
        end
    end
    return target
end

--- Construct a client
---@param uri string Service address (e.g. "http://host/api", "tcp://host:port")
---@return Client
function _M.new(uri)
    local self = setmetatable({}, _M)
    self.uri = uri or "http://localhost"
    self.options = deep_copy(DEFAULT_OPTIONS)
    return self
end

--- Set socket provider (class method, process-wide)
-- Under OpenResty, inject cosocket: Yar.client.set_socket(ngx.socket)
-- After injection, all Client instances' outbound connections use cosocket (non-blocking + connection pool)
---@param provider table Socket provider (e.g. ngx.socket)
---@return Client class
function _M.set_socket(provider)
    Transport.set_socket(provider)
    return _M
end

--- Set HTTP provider (class method, process-wide)
-- Inject a third-party HTTP library (e.g. lua-resty-http) to replace the default manual HTTP implementation
---@param provider function HTTP provider function(url, opts) → body, err
---@return Client class
function _M.set_http_provider(provider)
    Transport.set_http_provider(provider)
    return _M
end

--- Set options (table-driven, unified interface)
-- Supports nested style ({ transport = { timeout = 3000 } }) and flat style ({ timeout = 3000 }).
-- Flat keys are routed to nested groups via FLAT_KEY_MAP, backward compatible with setopt("timeout", 3000).
-- Does not modify the caller's opts table (builds an intermediate routed table then merges).
---@param opts table Options key-value pairs
---@return self
function _M:set_options(opts)
    if not opts then return self end
    local routed = {}
    -- socket_provider 是类级配置，不写入实例 options
    if opts.socket_provider then
        Socket.set(opts.socket_provider)
    end
    -- 扁平 key 路由到嵌套组（构建中间表，不修改调用方 opts）
    for k, v in pairs(opts) do
        if k ~= "socket_provider" then
            local group = FLAT_KEY_MAP[k]
            if group then
                routed[group] = routed[group] or {}
                routed[group][k] = v
            else
                routed[k] = v
            end
        end
    end
    deep_merge(self.options, routed)
    return self
end

--- Set option (convenience method, single key-value pair)
---@param opt string Option name (packager/timeout/provider/token etc.)
---@param val any Option value
---@return self
function _M:setopt(opt, val)
    return self:set_options({ [opt] = val })
end

--- Initiate an RPC call
---@param method string Remote method name
---@param params table|nil Parameters array (default {})
---@return any retval Success return value; nil on error
---@return table|nil err Error object (Error.new) or nil on success
-- Error classification (structured Error object, err.code matches):
--   Error.TRANSPORT   Transport layer error (connection failure, send failure, HTTP status error)
--   Error.TIMEOUT     Timeout (connection timeout, read/write timeout)
--   Error.PROTOCOL    Protocol parse error (bad packet, packager mismatch, header validation failure)
--   Error.NOT_FOUND   Method not found (server status=1, message prefix "method not found")
--   Error.EXCEPTION   Method execution exception (server status=1, other errors)
function _M:call(method, params)
    if type(method) ~= "string" then
        error("method must be a string, got " .. type(method), 2)
    end
    params = params or {}
    Log.debug("→ " .. method)
    local proto = self.options.protocol
    local trans = self.options.transport
    local hooks = self.options.hooks
    local packager, packager_err = Packager.get(proto.packager)
    if not packager then
        return nil, Error.new(Error.PROTOCOL, packager_err or "unknown packager")
    end
    -- 构造请求并渲染协议消息。
    -- encode 路径用 error()（Lua 生态惯例），Protocol.render 内部不 pcall（JIT 可编译），
    -- pcall 在此边界捕获（ADR #37 修正：pcall 从 render 内部移到 client 边界）。
    local request = Request.new({
        method   = method,
        params   = params,
        provider = proto.provider,
        token    = proto.token,
    })
    local render_ok, message = pcall(Protocol.render, request, packager)
    if not render_ok then
        return nil, Error.new(Error.PROTOCOL, "render error: " .. tostring(message))
    end
    run_hook(hooks and hooks.on_request, method, params)
    -- 获取传输器：persistent 模式复用缓存的 transport 实例，避免每次 call 重建连接
    local t
    if trans.persistent and self._transport then
        t = self._transport
    else
        local transport = Transport.get(self.uri)
        t = transport.new()
        local ok, oerr = t:open(self.uri, self.options)
        if not ok then
            return nil, Error.new(Error.TRANSPORT, oerr)
        end
        if trans.persistent then
            self._transport = t
        end
    end
    ---@cast t table
    local resp_data, err = t:send(message)
    -- persistent 模式不 close（连接由 transport 持有跨 call 复用）；否则关闭
    if not trans.persistent then
        t:close()
    end
    if not resp_data then
        Log.warn("transport error: " .. tostring(err))
        if trans.persistent then
            self._transport = nil
            t:close()
        end
        local e = err or "unknown error"
        local err_obj
        if string.find(e, "timeout", 1, true) then
            err_obj = Error.new(Error.TIMEOUT, e)
        else
            err_obj = Error.new(Error.TRANSPORT, e)
        end
        run_hook(hooks and hooks.on_response, method, nil, err_obj)
        return nil, err_obj
    end
    Log.debug("← " .. method .. " " .. #resp_data .. " bytes")
    -- 解析响应（packager.unpack 对畸形数据返回 nil, err，parse 传播 nil, nil, err，无需 pcall）
    local payload, _, perr = Protocol.parse(resp_data, packager)
    if not payload then
        local err_obj = Error.new(Error.PROTOCOL, perr or "parse error")
        run_hook(hooks and hooks.on_response, method, nil, err_obj)
        return nil, err_obj
    end
    local response = Response.unpack(payload)
    if response.status ~= Response.STATUS_OK then
        local msg = response.err or "unknown error"
        local err_obj
        if string.match(msg, "^method not found") then
            err_obj = Error.new(Error.NOT_FOUND, msg)
        else
            err_obj = Error.new(Error.EXCEPTION, msg)
        end
        run_hook(hooks and hooks.on_response, method, nil, err_obj)
        return nil, err_obj
    end
    run_hook(hooks and hooks.on_response, method, response.retval, nil)
    return response.retval
end

return _M
