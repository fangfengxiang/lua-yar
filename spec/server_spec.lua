-- spec/server_spec.lua
-- Server Facade 测试：new + register_service + handle(spec) + listen/loop + set_options + hooks + error paths

local Yar = require("yar")
local Server = Yar.server
local Packager = require("yar.packager.packager")
local Request = require("yar.message.request")
local Response = require("yar.message.response")
local Protocol = require("yar.protocol.protocol")
local Socket = require("yar.transport.socket")
local helpers = require("spec.helpers")

after_each(function()
    Socket.set(nil)
end)

describe("server new", function()
    it("should construct with opts and service", function()
        local server = Server.new(
            { add = function(a, b) return a + b end },
            { timeout = 3000 }
        )
        assert.is_not_nil(server.dispatcher)
        assert.are.equal(3000, server.options.timeout)
        local names = server:list_methods()
        local set = {}
        for _, n in ipairs(names) do set[n] = true end
        assert.is_true(set["add"])
    end)

    it("should construct with service only (no opts)", function()
        local server = Server.new({ add = function(a, b) return a + b end })
        local set = {}
        for _, n in ipairs(server:list_methods()) do set[n] = true end
        assert.is_true(set["add"])
    end)

    it("should construct with opts only (no service)", function()
        local server = Server.new({}, { timeout = 5000 })
        assert.are.equal(5000, server.options.timeout)
        assert.are.equal(0, #server:list_methods())
    end)

    it("should construct with no args", function()
        local server = Server.new()
        assert.is_not_nil(server.dispatcher)
        assert.are.equal(0, #server:list_methods())
    end)

    it("should register single function as 'default'", function()
        local server = Server.new(function() return 42 end)
        local found = false
        for _, n in ipairs(server:list_methods()) do
            if n == "default" then found = true end
        end
        assert.is_true(found)
    end)
end)

describe("server register_service", function()
    it("should batch register public methods", function()
        local server = Server.new({
            add = function(a, b) return a + b end,
            sub = function(a, b) return a - b end,
            _private = function() return "secret" end,
        })
        local set = {}
        for _, n in ipairs(server:list_methods()) do set[n] = true end
        assert.is_true(set["add"])
        assert.is_true(set["sub"])
        assert.is_nil(set["_private"])
    end)

    it("should be chainable", function()
        local server = Server.new()
        local ret = server:register_service({ mul = function(a, b) return a * b end })
        assert.are.equal(server, ret)
    end)

    it("should merge methods from multiple calls", function()
        local server = Server.new()
        server:register_service({ add = function(a, b) return a + b end })
        server:register_service({ sub = function(a, b) return a - b end })
        local set = {}
        for _, n in ipairs(server:list_methods()) do set[n] = true end
        assert.is_true(set["add"])
        assert.is_true(set["sub"])
    end)
end)

describe("server register", function()
    it("should register a single method", function()
        local server = Server.new()
        server:register("mul", function(a, b) return a * b end)
        local set = {}
        for _, n in ipairs(server:list_methods()) do set[n] = true end
        assert.is_true(set["mul"])
    end)

    it("should be chainable", function()
        local server = Server.new()
        local ret = server:register("add", function(a, b) return a + b end)
        assert.are.equal(server, ret)
    end)

    it("should handle method registered via register in handle_message", function()
        local jp = Packager.get(Packager.JSON)
        local server = Server.new()
        server:register("add", function(a, b) return a + b end)
        local req = Request.new({ method = "add", params = { 3, 4 }, provider = "p", token = "t" })
        local resp = server.dispatcher:handle_message(Protocol.render(req, jp))
        local payload = Protocol.parse(resp, jp)
        assert.are.equal(7, payload.r)
    end)

    it("should error on invalid method name (starts with _)", function()
        local server = Server.new()
        local ok, err = pcall(function() server:register("_private", function() end) end)
        assert.is_false(ok)
        assert.truthy(string.find(err, "invalid method name"))
    end)

    it("should error on invalid method name (non-alphanumeric)", function()
        local server = Server.new()
        local ok, err = pcall(function() server:register("add-2", function() end) end)
        assert.is_false(ok)
        assert.truthy(string.find(err, "invalid method name"))
    end)

    it("should error on non-string method name", function()
        local server = Server.new()
        local ok, err = pcall(function() server:register(123, function() end) end)
        assert.is_false(ok)
        assert.truthy(string.find(err, "invalid method name"))
    end)

    it("should error on non-function func", function()
        local server = Server.new()
        local ok, err = pcall(function() server:register("add", "not a function") end)
        assert.is_false(ok)
        assert.truthy(string.find(err, "func must be a function"))
    end)
end)

describe("server handle (host mode)", function()
    local jp

    before_each(function()
        jp = Packager.get(Packager.JSON)
    end)

    it("should handle TCP socket mode", function()
        local server = Server.new({ add = function(a, b) return a + b end })
        server.protocol = "tcp"
        local req = Request.new({ method = "add", params = { 10, 20 }, provider = "p", token = "t" })
        local msg = Protocol.render(req, jp)
        local sock, sent = helpers.mock_tcp_socket(msg)
        local ok = server:handle({ socket = sock })
        assert.is_true(ok)
        local payload = Protocol.parse(table.concat(sent), jp)
        assert.are.equal(30, payload.r)
    end)

    it("should handle HTTP socket mode", function()
        local server = Server.new({ add = function(a, b) return a + b end })
        server.protocol = "http"
        local req = Request.new({ method = "add", params = { 10, 20 }, provider = "p", token = "t" })
        local msg = Protocol.render(req, jp)
        local http_req = "POST /api HTTP/1.1\r\nHost: localhost\r\nContent-Length: " .. #msg .. "\r\n\r\n" .. msg
        local sock, sent = helpers.mock_http_socket(http_req)
        local ok = server:handle({ socket = sock })
        assert.is_true(ok)
        local resp = table.concat(sent)
        assert.are.equal("HTTP/1.1 200", string.sub(resp, 1, 12))
    end)

    it("should handle HTTP callback mode (POST)", function()
        local server = Server.new({ add = function(a, b) return a + b end })
        local req = Request.new({ method = "add", params = { 10, 20 }, provider = "p", token = "t" })
        local msg = Protocol.render(req, jp)
        local captured_status, captured_body
        local writer = function(status, _, body)
            captured_status = status
            captured_body = body
        end
        local ok = server:handle({ method = "POST", data = msg, writer = writer })
        assert.is_true(ok)
        assert.are.equal(200, captured_status)
        local payload = Protocol.parse(captured_body, jp)
        assert.are.equal(30, payload.r)
    end)

    it("should handle HTTP callback mode (GET introspection)", function()
        local server = Server.new({ add = function() end, sub = function() end })
        local captured_status, captured_body
        local writer = function(status, _, body)
            captured_status = status
            captured_body = body
        end
        server:handle({ method = "GET", data = "", writer = writer })
        assert.are.equal(200, captured_status)
        local Json = require("yar.packager.json")
        local set = {}
        for _, n in ipairs(Json.unpack(captured_body)) do set[n] = true end
        assert.is_true(set["add"])
        assert.is_true(set["sub"])
    end)

    it("should return 405 for unsupported method in callback mode", function()
        local server = Server.new({ add = function() end })
        local captured_status
        server:handle({ method = "PUT", data = "", writer = function(s) captured_status = s end })
        assert.are.equal(405, captured_status)
    end)

    it("should return 400 for empty body in callback mode", function()
        local server = Server.new({ add = function() end })
        local captured_status
        server:handle({ method = "POST", data = "", writer = function(s) captured_status = s end })
        assert.are.equal(400, captured_status)
    end)

    it("should return 413 for oversized body in callback mode", function()
        local server = Server.new({ add = function() end }, { max_body_len = 10 })
        local captured_status, captured_body
        server:handle({ method = "POST", data = string.rep("x", 100),
            writer = function(s, _, b) captured_status = s; captured_body = b end })
        assert.are.equal(413, captured_status)
        assert.truthy(string.find(captured_body, "body too large", 1, true))
    end)

    it("should return nil, err for invalid spec", function()
        local server = Server.new({ add = function() end })
        local ok, err = server:handle({})
        assert.is_nil(ok)
        assert.truthy(string.find(err, "invalid spec"))
    end)

    it("should return nil, err for nil spec", function()
        local server = Server.new({ add = function() end })
        local ok, err = server:handle(nil)
        assert.is_nil(ok)
        assert.truthy(string.find(err, "spec"))
    end)

    it("should return nil, err when writer is not a function", function()
        local server = Server.new({ add = function() end })
        local ok, err = server:handle({ method = "POST", data = "x", writer = "not a function" })
        assert.is_nil(ok)
        assert.truthy(string.find(err, "writer"))
    end)
end)

describe("server handle_message (via dispatcher)", function()
    local jp

    before_each(function()
        jp = Packager.get(Packager.JSON)
    end)

    it("should handle JSON request and return correct retval", function()
        local server = Server.new({ add = function(a, b) return a + b end })
        local req = Request.new({ method = "add", params = { 10, 20 }, provider = "p", token = "t" })
        local msg = Protocol.render(req, jp)
        local payload, header = Protocol.parse(server.dispatcher:handle_message(msg), jp)
        assert.are.equal(30, payload.r)
        assert.are.equal(req.id, header.id)
    end)

    it("should handle Msgpack request with auto packager detection", function()
        local server = Server.new({ add = function(a, b) return a + b end })
        local mp = Packager.get(Packager.MSGPACK)
        local req = Request.new({ method = "add", params = { 7, 8 }, provider = "p", token = "t" })
        local msg = Protocol.render(req, mp)
        local resp = server.dispatcher:handle_message(msg)
        assert.are.equal(Packager.MSGPACK, string.sub(resp, 1, 7))
        local payload = Protocol.parse(resp, mp)
        assert.are.equal(15, payload.r)
    end)

    it("should return error response for short packet", function()
        local server = Server.new({ add = function(a, b) return a + b end })
        local resp = server.dispatcher:handle_message("JSON\0\0\0\0")
        assert.is_not_nil(resp)
        local payload = Protocol.parse(resp, jp)
        assert.are.equal(Response.STATUS_ERROR, payload.s)
    end)

    it("should fallback packager for unknown packager name", function()
        local server = Server.new({ add = function(a, b) return a + b end })
        local resp = server.dispatcher:handle_message("UNKNOWN\0\0" .. string.rep("\0", 82))
        assert.is_not_nil(resp)
    end)

    it("should retry with error response on encode error (cyclic)", function()
        local server = Server.new({ cyclic = function() local t = {}; t.self = t; return t end })
        local req = Request.new({ method = "cyclic", params = {}, provider = "p", token = "t" })
        local resp = server.dispatcher:handle_message(Protocol.render(req, jp))
        assert.is_not_nil(resp)
        local payload = Protocol.parse(resp, jp)
        assert.are.equal(Response.STATUS_ERROR, payload.s)
        assert.truthy(string.find(payload.e, "encode error"))
    end)
end)

describe("server set_options / set_packager / setopt", function()
    it("should set packager via set_options", function()
        local server = Server.new({ add = function() end })
        server:set_options({ packager = Packager.MSGPACK, timeout = 3000 })
        assert.are.equal(Packager.get(Packager.MSGPACK), server.dispatcher.packager)
        assert.are.equal(3000, server.options.timeout)
    end)

    it("should set packager via set_packager", function()
        local server = Server.new({ add = function() end })
        server:set_packager(Packager.JSON)
        assert.are.equal(Packager.get(Packager.JSON), server.dispatcher.packager)
    end)

    it("should set single option via setopt", function()
        local server = Server.new({ add = function() end })
        server:setopt("timeout", 8000)
        assert.are.equal(8000, server.options.timeout)
    end)

    it("should be a no-op on set_options(nil)", function()
        local server = Server.new({ add = function() end })
        server:set_options({ timeout = 9999 })
        server:set_options(nil)
        assert.are.equal(9999, server.options.timeout)
    end)

    it("should route socket_provider via set_options", function()
        local tcp_called = false
        local custom_provider = {
            tcp = function() tcp_called = true; return nil end,
            bind = function() return nil end,
        }
        local server = Server.new({ add = function() end })
        server:set_options({ socket_provider = custom_provider })
        Socket.tcp()
        assert.is_true(tcp_called)
    end)

    it("should route socket_provider via constructor opts", function()
        local tcp_called = false
        local custom_provider = {
            tcp = function() tcp_called = true; return nil end,
            bind = function() return nil end,
        }
        local _ = Server.new({ add = function() end }, { socket_provider = custom_provider })
        Socket.tcp()
        assert.is_true(tcp_called)
    end)

    it("should be chainable", function()
        local server = Server.new({ add = function() end })
        assert.are.equal(server, server:set_packager(Packager.JSON))
        assert.are.equal(server, server:set_options({ timeout = 1000 }))
        assert.are.equal(server, server:setopt("timeout", 2000))
        assert.are.equal(server, server:register_service({ mul = function() end }))
    end)
end)

describe("server hooks", function()
    local jp

    before_each(function()
        jp = Packager.get(Packager.JSON)
    end)

    it("should trigger on_request/on_response on success", function()
        local req_log, resp_log = {}, {}
        local server = Server.new(
            { add = function(a, b) return a + b end },
            { hooks = { on_request = function(m, p) req_log.m = m; req_log.p = p end,
                        on_response = function(m, r, e) resp_log.m = m; resp_log.r = r; resp_log.e = e end } }
        )
        local req = Request.new({ method = "add", params = { 10, 20 }, provider = "p", token = "t" })
        server.dispatcher:handle_message(Protocol.render(req, jp))
        assert.are.equal("add", req_log.m)
        assert.are.equal(10, req_log.p[1])
        assert.are.equal("add", resp_log.m)
        assert.are.equal(30, resp_log.r)
        assert.is_nil(resp_log.e)
    end)

    it("should trigger on_response with NOT_FOUND error", function()
        local resp_log = {}
        local server = Server.new(
            { add = function(a, b) return a + b end },
            { hooks = { on_response = function(_, _, e) resp_log.e = e end } }
        )
        local req = Request.new({ method = "nope", params = {}, provider = "p", token = "t" })
        server.dispatcher:handle_message(Protocol.render(req, jp))
        assert.are.equal(Yar.error.NOT_FOUND, resp_log.e.code)
    end)

    it("should trigger on_response with EXCEPTION error", function()
        local resp_log = {}
        local server = Server.new(
            { crash = function() error("boom") end },
            { hooks = { on_response = function(_, _, e) resp_log.e = e end } }
        )
        local req = Request.new({ method = "crash", params = {}, provider = "p", token = "t" })
        server.dispatcher:handle_message(Protocol.render(req, jp))
        assert.are.equal(Yar.error.EXCEPTION, resp_log.e.code)
        assert.truthy(string.find(resp_log.e.message, "boom"))
    end)

    it("should protect main flow from hook errors via pcall", function()
        local server = Server.new(
            { add = function(a, b) return a + b end },
            { hooks = { on_request = function() error("hook crash") end,
                        on_response = function() error("hook crash") end } }
        )
        local req = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })
        local resp = server.dispatcher:handle_message(Protocol.render(req, jp))
        assert.is_not_nil(resp)
        local payload = Protocol.parse(resp, jp)
        assert.are.equal(3, payload.r)
    end)
end)

describe("server handle_message (via Facade)", function()
    local jp

    before_each(function()
        jp = Packager.get(Packager.JSON)
    end)

    it("should delegate to dispatcher and return correct retval", function()
        local server = Server.new({ add = function(a, b) return a + b end })
        local req = Request.new({ method = "add", params = { 10, 20 }, provider = "p", token = "t" })
        local resp = server:handle_message(Protocol.render(req, jp))
        assert.is_not_nil(resp)
        local payload = Protocol.parse(resp, jp)
        assert.are.equal(30, payload.r)
    end)

    it("should return error response for method not found", function()
        local server = Server.new({ add = function(a, b) return a + b end })
        local req = Request.new({ method = "nope", params = {}, provider = "p", token = "t" })
        local resp = server:handle_message(Protocol.render(req, jp))
        assert.is_not_nil(resp)
        local payload = Protocol.parse(resp, jp)
        assert.are.equal(Response.STATUS_ERROR, payload.s)
        assert.truthy(string.find(payload.e, "method not found"))
    end)

    it("should return error response for invalid data (short packet)", function()
        local server = Server.new({ add = function(a, b) return a + b end })
        local resp = server:handle_message("JSON\0\0\0\0")
        assert.is_not_nil(resp)
        local payload = Protocol.parse(resp, jp)
        assert.are.equal(Response.STATUS_ERROR, payload.s)
    end)
end)

describe("server addr parsing (listen)", function()
    it("should parse tcp://host:port", function()
        local captured_host, captured_port
        Socket.set({
            bind = function(host, port) captured_host = host; captured_port = port; return nil, "err" end,
            tcp = function() return nil end,
        })
        local server = Server.new({ add = function() end })
        server:listen("tcp://0.0.0.0:8888")
        assert.are.equal("0.0.0.0", captured_host)
        assert.are.equal(8888, captured_port)
        assert.are.equal("tcp", server.protocol)
    end)

    it("should parse http://host:port", function()
        local captured_port
        Socket.set({
            bind = function(_, port) captured_port = port; return nil, "err" end,
            tcp = function() return nil end,
        })
        local server = Server.new({ add = function() end })
        server:listen("http://0.0.0.0:9090")
        assert.are.equal(9090, captured_port)
        assert.are.equal("http", server.protocol)
    end)

    it("should default port 80 for http://host without port", function()
        local captured_port
        Socket.set({
            bind = function(_, port) captured_port = port; return nil, "err" end,
            tcp = function() return nil end,
        })
        local server = Server.new({ add = function() end })
        server:listen("http://0.0.0.0")
        assert.are.equal(80, captured_port)
    end)

    it("should reject tcp://host without port", function()
        local server = Server.new({ add = function() end })
        local ok, err = server:listen("tcp://0.0.0.0")
        assert.is_nil(ok)
        assert.truthy(string.find(err, "port"))
    end)

    it("should reject empty addr", function()
        local server = Server.new({ add = function() end })
        local ok, err = server:listen("")
        assert.is_nil(ok)
        assert.truthy(string.find(err, "non%-empty"))
    end)

    it("should reject unsupported scheme", function()
        local server = Server.new({ add = function() end })
        local ok, err = server:listen("ftp://0.0.0.0:8888")
        assert.is_nil(ok)
        assert.truthy(string.find(err, "unsupported"))
    end)

    it("should return nil, err on bind failure", function()
        Socket.set({
            bind = function() return nil, "address in use" end,
            tcp = function() return nil end,
        })
        local server = Server.new({ add = function() end })
        local ok, err = server:listen("tcp://0.0.0.0:80")
        assert.is_nil(ok)
        assert.truthy(string.find(err, "bind failed"))
    end)
end)

describe("server loop", function()
    it("should return nil, err when listen_sock not set", function()
        local server = Server.new({ add = function() end })
        local ok, err = server:loop()
        assert.is_nil(ok)
        assert.truthy(string.find(err, "listen"))
    end)

    it("should accept and handle a connection then break on accept error", function()
        local accept_count = 0
        local mock_client = {
            settimeout = function() end,
            close = function() end,
            receive = function() return nil end,
            send = function() return 0 end,
        }
        local mock_server = {
            settimeout = function() end,
            accept = function()
                accept_count = accept_count + 1
                if accept_count == 1 then return mock_client end
                error("accept error")
            end,
        }
        Socket.set({
            bind = function() return mock_server end,
            tcp = function() return nil end,
        })
        local server = Server.new({ add = function(a, b) return a + b end })
        server:listen("tcp://0.0.0.0:9999")
        local ok = pcall(function() server:loop() end)
        assert.is_false(ok)
    end)
end)
