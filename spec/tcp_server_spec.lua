-- spec/tcp_server_spec.lua
-- TcpTransport 测试：serve(sock, dispatcher, spec, opts) 集成测试
-- TcpServer 类已移除，测试迁移到 Server Facade + TcpTransport

local Server = require("yar.server")
local TcpTransport = require("yar.server.tcp")
local Packager = require("yar.packager.packager")
local Request = require("yar.message.request")
local Protocol = require("yar.protocol.protocol")
local helpers = require("spec.helpers")

describe("tcp transport serve", function()
    local jp, dispatcher

    before_each(function()
        jp = Packager.get(Packager.JSON)
        dispatcher = Server.new({
            add = function(a, b) return a + b end,
            sub = function(a, b) return a - b end,
        }).dispatcher
    end)

    it("should handle single message", function()
        local req = Request.new({ method = "add", params = { 10, 20 }, provider = "p", token = "t" })
        local msg = Protocol.render(req, jp)
        local sock, sent = helpers.mock_tcp_socket(msg)
        TcpTransport.serve(sock, dispatcher, { keepalive = false })
        local payload, header = Protocol.parse(table.concat(sent), jp)
        assert.are.equal(30, payload.r)
        assert.are.equal(req.id, header.id)
    end)

    it("should handle keepalive mode with two messages", function()
        local req = Request.new({ method = "add", params = { 10, 20 }, provider = "p", token = "t" })
        local msg = Protocol.render(req, jp)
        local req2 = Request.new({ method = "sub", params = { 20, 5 }, provider = "p", token = "t" })
        local msg2 = Protocol.render(req2, jp)
        local sock, sent = helpers.mock_tcp_socket(msg .. msg2)
        TcpTransport.serve(sock, dispatcher, { keepalive = true })
        local resp_data = table.concat(sent)
        local payload1, header1 = Protocol.parse(resp_data, jp)
        assert.are.equal(30, payload1.r)
        assert.are.equal(req.id, header1.id)
        local first_len = 8 + 82 + header1.body_len
        local payload2, header2 = Protocol.parse(string.sub(resp_data, first_len + 1), jp)
        assert.are.equal(15, payload2.r)
        assert.are.equal(req2.id, header2.id)
    end)

    it("should not send data on closed connection", function()
        local sock, sent = helpers.mock_tcp_socket("")
        TcpTransport.serve(sock, dispatcher, { keepalive = false })
        assert.are.equal(0, #sent)
    end)

    it("should send first response before disconnect in keepalive", function()
        local req = Request.new({ method = "add", params = { 10, 20 }, provider = "p", token = "t" })
        local msg = Protocol.render(req, jp)
        local sock, sent = helpers.mock_tcp_socket(msg)
        TcpTransport.serve(sock, dispatcher, { keepalive = true })
        local resp_data = table.concat(sent)
        assert.truthy(#resp_data > 0)
        local payload = Protocol.parse(resp_data, jp)
        assert.are.equal(30, payload.r)
    end)

    it("should break keepalive loop when receive returns nil", function()
        local sock, sent = helpers.mock_tcp_socket("")
        TcpTransport.serve(sock, dispatcher, { keepalive = true })
        assert.are.equal(0, #sent)
    end)

    it("should break keepalive loop when send fails", function()
        local req = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })
        local msg = Protocol.render(req, jp)
        local sock = helpers.mock_tcp_socket(msg)
        sock.send = function() return nil, "broken pipe" end
        TcpTransport.serve(sock, dispatcher, { keepalive = true })
    end)

    it("should not send response when handle_message fails in single mode", function()
        local sock, sent = helpers.mock_tcp_socket("invalid-data")
        TcpTransport.serve(sock, dispatcher, { keepalive = false })
        assert.are.equal(0, #sent)
    end)

    it("should return early when send fails in single mode", function()
        local req = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })
        local msg = Protocol.render(req, jp)
        local sock = helpers.mock_tcp_socket(msg)
        sock.send = function() return nil, "send error" end
        TcpTransport.serve(sock, dispatcher, { keepalive = false })
    end)

    it("should use opts.keepalive when spec.keepalive not set", function()
        local req = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })
        local msg = Protocol.render(req, jp)
        local sock, sent = helpers.mock_tcp_socket(msg)
        TcpTransport.serve(sock, dispatcher, nil, { keepalive = false })
        assert.truthy(#sent > 0)
    end)
end)

describe("tcp transport via Server Facade handle", function()
    local jp

    before_each(function()
        jp = Packager.get(Packager.JSON)
    end)

    it("should handle TCP socket via server:handle", function()
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

    it("should pass keepalive option through spec", function()
        local server = Server.new({ add = function(a, b) return a + b end })
        server.protocol = "tcp"
        local req1 = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })
        local req2 = Request.new({ method = "add", params = { 3, 4 }, provider = "p", token = "t" })
        local msg = Protocol.render(req1, jp) .. Protocol.render(req2, jp)
        local sock, sent = helpers.mock_tcp_socket(msg)
        server:handle({ socket = sock, keepalive = true })
        local resp_data = table.concat(sent)
        assert.truthy(#resp_data > 0)
    end)
end)
