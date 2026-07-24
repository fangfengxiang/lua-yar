-- yar/server/dispatcher.lua
-- YAR 协议核心：纯协议处理，不感知任何传输层（ngx / luasocket）。
--
-- 核心契约：handle_message(data) 接收一条完整 YAR 二进制消息（packager+header+body），
-- 解析、派发到已注册的方法，返回 YAR 二进制响应消息。与 HTTP/TCP 无关，无 I/O、无 yield，
-- reentrant，可被任意协程 / OpenResty location 直接调用。
-- 传输层（如何拿到 data、如何把响应写回）由调用方负责，见 server/tcp、server/http。

local Request  = require("yar.message.request")
local Response = require("yar.message.response")
local Protocol = require("yar.protocol.protocol")
local Framing  = require("yar.protocol.framing")
local Packager = require("yar.packager.packager")
local Util     = require("yar.util")
local Log      = require("yar.log")
local Error    = require("yar.error")
local ServerConst = require("yar.server.constants")

local tostring, pcall, type, pairs, string, error, setmetatable =
    tostring, pcall, type, pairs, string, error, setmetatable

local DEFAULT_TIMEOUT      = ServerConst.DEFAULT_TIMEOUT
local DEFAULT_MAX_BODY_LEN = ServerConst.DEFAULT_MAX_BODY_LEN

-- unpack 兼容（Lua 5.1/LuaJIT 为全局 unpack，5.2+ 为 table.unpack）
-- lua-language-server 对全局 unpack 报 deprecated WARNING，此处为跨版本兼容写法（业界标杆库
-- 如 dkjson/lua-MessagePack 均用此模式），lint 误报故抑制。
---@diagnostic disable-next-line: deprecated
local unpack = unpack or table["unpack"]

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

--- Collect public methods from service object (excludes private methods starting with _)
---@param service table|function Service object, or single function (registered as "default")
---@return table {name = func}
local function collect_methods(service)
    local methods = {}
    if type(service) == "table" then
        for name, func in pairs(service) do
            if type(func) == "function" and type(name) == "string" and not string.match(name, "^_") then
                methods[name] = func
            end
        end
    elseif type(service) == "function" then
        methods.default = service
    end
    return methods
end

--- Validate RPC method name (non-empty string, alphanumeric + underscore, not starting with _)
-- 与 collect_methods 的 ^_ 过滤一致，额外校验字母数字字符集。
-- register_service 用 collect_methods 自动过滤（信任 service 对象键名），
-- register 接受外部 name 字符串，需严格校验。
---@param name any Method name candidate
---@return boolean valid
local function is_valid_method_name(name)
    if type(name) ~= "string" or #name == 0 then
        return false
    end
    local first = string.byte(name, 1)
    if first == 95 then return false end  -- '_' 不允许开头
    for i = 1, #name do
        local b = string.byte(name, i)
        -- a-z: 97-122, A-Z: 65-90, 0-9: 48-57, _: 95
        if not ((b >= 97 and b <= 122) or (b >= 65 and b <= 90)
            or (b >= 48 and b <= 57) or b == 95) then
            return false
        end
    end
    return true
end

---@class Dispatcher
---@field packager table Packager module
---@field methods table<string, function> Registered methods
---@field options table Server options
local _M = {}
_M.__index = _M

--- Construct a Dispatcher
---@param opts table|nil Server options (packager, max_body_len, timeout, hooks, etc.)
---@return Dispatcher
function _M.new(opts)
    local self = setmetatable({}, _M)
    local p = Packager.get(Packager.JSON) ---@cast p table
    self.packager = p
    self.methods = {}
    self.options = { timeout = DEFAULT_TIMEOUT, max_body_len = DEFAULT_MAX_BODY_LEN }
    if opts then
        self:set_options(opts)
    end
    return self
end

--- Register a service object (batch registration, chainable)
-- Auto-collects public methods (function type, not _ prefixed).
-- Aligns with PHP Yar new Yar_Server($service), Go rpc.Register(recv).
---@param service table|function Service object (function fields = RPC methods, _ prefix = private)
---@return Dispatcher self (chainable)
function _M:register_service(service)
    local methods = collect_methods(service)
    for name, func in pairs(methods) do
        self.methods[name] = func
    end
    return self
end

--- Register a single method (chainable)
-- Validates method name (alphanumeric + underscore, not _ prefixed) and func type.
-- Aligns with yar-c yar_server_register_handler, Python SimpleXMLRPCServer.register_function.
-- Programming errors (bad name/func type) → error(msg, 2) fail-fast.
---@param name string Method name (alphanumeric + underscore, not _ prefixed)
---@param func function Method function
---@return Dispatcher self (chainable)
function _M:register(name, func)
    if not is_valid_method_name(name) then
        error("invalid method name: " .. tostring(name), 2)
    end
    if type(func) ~= "function" then
        error("func must be a function, got " .. type(func), 2)
    end
    self.methods[name] = func
    return self
end

--- Set packager (response encoding format)
---@param name string Packager name: Packager.JSON or Packager.MSGPACK
---@return Dispatcher self
function _M:set_packager(name)
    local p, err = Packager.get(name)
    if not p then
        error(tostring(err), 2)
    end
    self.packager = p
    return self
end

--- Set options (table-driven, unified interface)
---@param opts table Options key-value pairs (packager/timeout etc.)
---@return Dispatcher self
function _M:set_options(opts)
    if not opts then return self end
    for k, v in pairs(opts) do
        if k == "packager" then
            self:set_packager(v)
        else
            self.options[k] = v
        end
    end
    return self
end

--- Set option (convenience method, single key-value pair)
---@param opt string Option name
---@param val any Option value
---@return Dispatcher self
function _M:setopt(opt, val)
    return self:set_options({ [opt] = val })
end

--- List registered method names (for GET introspection / documentation)
---@return table Method name array
function _M:list_methods()
    local names = {}
    for name in pairs(self.methods) do
        names[#names + 1] = name
    end
    return names
end

--- Render a message with pcall protection at the boundary
-- encode 路径用 error()（Lua 生态惯例），Protocol.render 内部不 pcall（JIT 可编译），
-- pcall 在此边界捕获（ADR #37 修正：pcall 从 render 内部移到 dispatcher 边界）。
---@param message table Request or Response object
---@param packager table Packager module
---@return string|nil rendered binary message (nil on encode error)
---@return string|nil err Error message
local function safe_render(message, packager)
    local ok, rendered = pcall(Protocol.render, message, packager)
    if not ok then
        return nil, tostring(rendered)
    end
    return rendered
end

--- Pack data for GET introspection response
-- GET introspection 不是热路径（仅 GET 请求触发），保留 pcall 无性能影响。
---@param data any Data to pack (method list or other)
---@return string|nil packed data
---@return string|nil err error message
function _M:pack(data)
    local ok, payload = pcall(self.packager.pack, data)
    if not ok then
        return nil, tostring(payload)
    end
    return payload
end

--- Handle a YAR request message and return a response message
---@param data string YAR binary request message (packager + header + body)
---@return string|nil rendered YAR binary response message (nil on render error)
---@return string|nil err Error message (nil on success)
function _M:handle_message(data)
    -- 输入校验：data 必须是字符串且至少包含 packager(8) + header(82) = 90 字节
    -- 短于最小帧长直接拒绝，避免后续 string.sub/Header.unpack 对畸形输入级联报错
    if type(data) ~= "string" or #data < Framing.HEADER_TOTAL then
        local resp = Response.new({ id = 0 })
        resp:set_error("invalid request: data must be a string of at least " .. Framing.HEADER_TOTAL .. " bytes")
        return safe_render(resp, self.packager)
    end
    -- body 长度上限校验：防止恶意大 body 导致内存耗尽
    local max_body_len = self.options.max_body_len or DEFAULT_MAX_BODY_LEN
    if #data > max_body_len + Framing.HEADER_TOTAL then
        local resp = Response.new({ id = 0 })
        resp:set_error("body too large: " .. #data .. " bytes (max " .. max_body_len .. ")")
        return safe_render(resp, self.packager)
    end
    -- 从消息头部读取 packager 名称，按客户端声明的 packager 解析与响应
    -- 客户端声明的 packager 未知时回退到 self.packager。
    -- 注意：错误响应也用此 packager 渲染，packager_name 字段可能与请求头不匹配，
    -- 但这是最佳努力策略——客户端无法解析未知 packager 的响应。
    local name = Util.trim_null(string.sub(data, 1, 8))
    local packager = Packager.get(name)
    if not packager then
        packager = self.packager
    end
    -- packager.unpack 对畸形数据返回 nil, err（decode 路径，ADR #34），parse 传播 nil, nil, err，无需 pcall。
    -- encode 路径用 error()（Lua 生态惯例），Protocol.render 内部不 pcall，
    -- safe_render 在此边界 pcall 捕获（ADR #37 修正）。
    local payload, header, err = Protocol.parse(data, packager)
    if not payload or not header then
        local resp = Response.new({ id = 0 })
        resp:set_error(err or "parse error")
        return safe_render(resp, packager)
    end
    local request = Request.new({
        id       = payload.i,
        method   = payload.m,
        params   = payload.p,
        provider = header.provider,
        token    = header.token,
    })
    local hooks = self.options.hooks
    run_hook(hooks and hooks.on_request, request.method, request.params)
    local response = Response.new({
        id       = request.id,
        provider = header.provider,
        token    = header.token,
    })
    local func = self.methods[request.method]   -- memoize：不再每请求遍历 service
    if not func then
        local err_msg = "method not found: " .. tostring(request.method)
        response:set_error(err_msg)
        run_hook(hooks and hooks.on_response, request.method, nil, Error.new(Error.NOT_FOUND, err_msg))
    else
        local args = request.params or {}
        local call_ok, ret = pcall(func, unpack(args))
        if call_ok then
            response:set_retval(ret)
            run_hook(hooks and hooks.on_response, request.method, ret, nil)
        else
            local err_msg = tostring(ret)
            response:set_error(err_msg)
            run_hook(hooks and hooks.on_response, request.method, nil, Error.new(Error.EXCEPTION, err_msg))
        end
    end
    local rendered, rerr = safe_render(response, packager)
    if not rendered then
        -- encode 失败（循环引用/深度超限/cjson 抛错），构造错误响应重试
        response:set_error("encode error: " .. tostring(rerr))
        rendered, rerr = safe_render(response, packager)
        if not rendered then
            return nil, rerr
        end
    end
    return rendered
end

return _M
