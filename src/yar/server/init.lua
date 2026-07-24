-- yar/server/init.lua
-- Yar Server Facade：统一入口，隐藏三层内部架构（Dispatcher / Transport / Daemon）。
--
-- API:
--   Server.new(service?, opts?) -> Server     构造器（只初始化，不碰 I/O）
--   Server:handle(spec) -> true|nil, err      宿主模式入口
--   Server:listen(addr) -> true|nil, err      原生模式入口 1：解析 addr + bind
--   Server:loop() -> nil|nil, err              原生模式入口 2：accept 循环
--   Server:register_service(service) -> Server  链式
--   Server:register(name, func) -> Server        链式
--   Server:set_packager(name) -> Server        链式
--   Server:set_options(opts) -> Server          链式
--   Server:setopt(opt, val) -> Server          链式
--   Server:handle_message(data) -> string|nil, err  纯协议处理（委托 Dispatcher）
--   Server:list_methods() -> table
--
-- 内部架构（三层分离，Facade 隐藏）：
--   Dispatcher（dispatcher.lua）：协议核心，handle_message + register_service + list_methods + pack。无 I/O，无 yield，reentrant
--   TcpTransport/HttpTransport（tcp.lua/http.lua）：I/O 层，serve 函数
--   Daemon（daemon.lua）：accept 循环（bind 已在 listen() 完成），委托 server:handle

local Dispatcher    = require("yar.server.dispatcher")
local TcpTransport  = require("yar.server.tcp")
local HttpTransport = require("yar.server.http")
local Daemon        = require("yar.server.daemon")
local Socket        = require("yar.transport.socket")
local TransportConst = require("yar.transport.constants")
local Log           = require("yar.log")

local tostring, type, string, setmetatable, pairs, tonumber =
    tostring, type, string, setmetatable, pairs, tonumber

---@class Server
---@field dispatcher Dispatcher Protocol dispatcher
---@field options table Server options
---@field protocol string|nil "tcp" | "http" | "unix" (set by listen)
---@field host string|nil Listen host (set by listen)
---@field port number|nil Listen port (set by listen)
---@field unix_path string|nil Unix socket path (set by listen)
---@field listen_sock table|nil Listening socket (set by listen)
local _M = {}
_M.__index = _M

--- Parse address string into protocol, host, port (or unix_path)
-- Supported formats:
--   tcp://host:port    (port required)
--   http://host:port   (port optional, default 80 per RFC 3986)
--   http://host        (default port 80)
--   unix:///path       (unix domain socket)
---@param addr string Address string
---@return string|nil protocol "tcp", "http", or "unix"
---@return string|nil host Host (for tcp/http)
---@return number|nil port Port (for tcp/http)
---@return string|nil unix_path Path (for unix)
---@return string|nil err Error message
local function parse_addr(addr)
    if type(addr) ~= "string" or #addr == 0 then
        return nil, nil, nil, nil, "addr must be a non-empty string"
    end

    -- unix:///path
    local unix_path = string.match(addr, "^unix://(/.+)$")
    if unix_path then
        return "unix", nil, nil, unix_path, nil
    end

    -- tcp://host:port (port required)
    local proto, host, port = string.match(addr, "^(tcp)://([^:]+):(%d+)$")
    if proto then
        return proto, host, tonumber(port), nil, nil
    end

    -- http://host:port
    proto, host, port = string.match(addr, "^(http)://([^:]+):(%d+)$")
    if proto then
        return proto, host, tonumber(port), nil, nil
    end

    -- http://host (default port 80, RFC 3986)
    host = string.match(addr, "^http://([^:/]+)$")
    if host then
        return "http", host, TransportConst.HTTP_PORT, nil, nil
    end

    -- tcp://host without port is invalid
    if string.match(addr, "^tcp://") then
        return nil, nil, nil, nil, "tcp address requires port: tcp://host:port"
    end

    -- http://host:non-numeric-port or other http:// format
    if string.match(addr, "^http://") then
        return nil, nil, nil, nil, "invalid http address: " .. addr
    end

    return nil, nil, nil, nil, "unsupported address scheme: " .. addr
end

--- Construct a Server
-- Constructor only does initialization (service/opts), no I/O, no address.
-- Aligns with PHP Yar new Yar_Server($service), Ruby DRb start_service(uri, front, config).
---@param service table|function|nil Service object (function fields = RPC methods, _ prefix = private)
---@param opts table|nil Server options (packager, max_body_len, timeout, keepalive, hooks, socket_provider, ...)
---@return Server
function _M.new(service, opts)
    local self = setmetatable({}, _M)
    self.dispatcher = Dispatcher.new()
    self.options = self.dispatcher.options
    if opts then
        self:set_options(opts)
    end
    if service then
        self:register_service(service)
    end
    return self
end

--- Handle a request (host mode entry point)
-- Strategy determined by spec field presence:
--   spec.socket -> socket mode (TCP/HTTP by self.protocol)
--   spec.{method, data, writer} -> HTTP callback mode
---@param spec table Request spec
---@return boolean|nil ok true on success, nil on error
---@return string|nil err Error message
function _M:handle(spec)
    if not spec then
        return nil, "spec is required"
    end
    if spec.socket then
        local transport = self.protocol == "http"
            and HttpTransport or TcpTransport
        transport.serve(spec.socket, self.dispatcher, spec, self.options)
        return true
    end
    if spec.data ~= nil then
        return HttpTransport.serve_callback(spec, self.dispatcher, self.options)
    end
    return nil, "invalid spec: need socket or {method, data, writer}"
end

--- Listen on an address (native mode entry 1: parse addr + bind)
-- I/O operation, returns true|nil, err (non-chaining, aligns with httpc:connect()).
-- Supported formats: tcp://host:port, http://host:port, http://host (default 80), unix:///path
---@param addr string Address string
---@return boolean|nil true on success
---@return string|nil err Error message
function _M:listen(addr)
    local protocol, host, port, unix_path, err = parse_addr(addr)
    if not protocol then
        return nil, err
    end
    self.protocol = protocol
    self.host = host
    self.port = port
    self.unix_path = unix_path

    local listen_sock, berr
    if protocol == "unix" then
        listen_sock, berr = Socket.bind_unix(unix_path or "")
    else
        listen_sock, berr = Socket.bind(host, port)
    end
    if not listen_sock then
        return nil, "bind failed: " .. tostring(berr)
    end
    listen_sock:settimeout(nil)
    self.listen_sock = listen_sock

    local addr_display = protocol == "unix"
        and unix_path
        or (host .. ":" .. port)
    Log.info("Server listening on " .. addr_display)
    return true
end

--- Run accept loop (native mode entry 2: accept + handle)
-- WARNING: Sequential accept, one connection at a time, blocking.
-- For concurrency, pass server.listen_sock to copas.addserver() or use OpenResty.
-- Prerequisite: self.listen_sock must be set by listen().
---@return nil|nil, string|nil Returns nil, err if listen_sock not set; otherwise loops forever
function _M:loop()
    return Daemon.run(self)
end

--- Register a service object (batch registration, chainable, delegates to Dispatcher)
---@param service table|function Service object
---@return Server self (chainable)
function _M:register_service(service)
    self.dispatcher:register_service(service)
    return self
end

--- Register a single method (chainable, delegates to Dispatcher)
-- Validates method name and func type. Aligns with yar-c yar_server_register_handler,
-- Python SimpleXMLRPCServer.register_function.
---@param name string Method name (alphanumeric + underscore, not _ prefixed)
---@param func function Method function
---@return Server self (chainable)
function _M:register(name, func)
    self.dispatcher:register(name, func)
    return self
end

--- Set packager (chainable, delegates to Dispatcher)
---@param name string Packager name: Packager.JSON or Packager.MSGPACK
---@return Server self
function _M:set_packager(name)
    self.dispatcher:set_packager(name)
    return self
end

--- Set options (table-driven, chainable, delegates to Dispatcher)
---@param opts table Options key-value pairs
---@return Server self
function _M:set_options(opts)
    if not opts then return self end
    local disp_opts = nil
    for k, v in pairs(opts) do
        if k == "socket_provider" then
            Socket.set(v)
        else
            disp_opts = disp_opts or {}
            disp_opts[k] = v
        end
    end
    if disp_opts then
        self.dispatcher:set_options(disp_opts)
    end
    return self
end

--- Set option (convenience method, single key-value pair, chainable)
---@param opt string Option name
---@param val any Option value
---@return Server self
function _M:setopt(opt, val)
    return self:set_options({ [opt] = val })
end

--- List registered method names (delegates to Dispatcher)
---@return table Method name array
function _M:list_methods()
    return self.dispatcher:list_methods()
end

--- Handle a YAR protocol message (delegates to Dispatcher)
-- Pure protocol function: no I/O, no yield, reentrant.
-- Any runtime (OpenResty content_by_lua, lua-eco coroutine, Skynet) can call this directly.
---@param data string YAR binary message
---@return string|nil Response binary message, nil on error
---@return string|nil err Error message
function _M:handle_message(data)
    return self.dispatcher:handle_message(data)
end

return _M
