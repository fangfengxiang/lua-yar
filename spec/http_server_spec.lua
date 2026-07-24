-- spec/http_server_spec.lua
-- HttpTransport 测试：serve(sock, dispatcher, opts) socket 模式 + serve_callback(spec, dispatcher, opts) 回调模式
-- HttpServer 类已移除，测试迁移到 Server Facade + HttpTransport

local Server = require("yar.server")
local HttpTransport = require("yar.server.http")
local Packager = require("yar.packager.packager")
local Json = require("yar.packager.json")
local Request = require("yar.message.request")
local Protocol = require("yar.protocol.protocol")
local helpers = require("spec.helpers")

describe("http transport serve (socket mode)", function()
    local jp, dispatcher

    before_each(function()
        jp = Packager.get(Packager.JSON)
        dispatcher = Server.new({
            add = function(a, b) return a + b end,
        }).dispatcher
    end)

    it("should handle POST request", function()
        local req = Request.new({ method = "add", params = { 10, 20 }, provider = "p", token = "t" })
        local msg = Protocol.render(req, jp)
        local http_req = "POST /api HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            .. "Content-Type: application/octet-stream\r\n"
            .. "Content-Length: " .. #msg .. "\r\n\r\n" .. msg
        local sock, sent = helpers.mock_http_socket(http_req)
        HttpTransport.serve(sock, dispatcher)
        local resp = table.concat(sent)
        assert.are.equal("HTTP/1.1 200", string.sub(resp, 1, 12))
        assert.truthy(string.find(resp, "application/octet-stream", 1, true))
        local _, body_start = string.find(resp, "\r\n\r\n", 1, true)
        local body = string.sub(resp, body_start + 1)
        local payload, header = Protocol.parse(body, jp)
        assert.are.equal(30, payload.r)
        assert.are.equal(req.id, header.id)
    end)

    it("should return method list on GET request", function()
        local get_req = "GET /api HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        local sock, sent = helpers.mock_http_socket(get_req)
        HttpTransport.serve(sock, dispatcher)
        local resp = table.concat(sent)
        assert.are.equal("HTTP/1.1 200", string.sub(resp, 1, 12))
        assert.truthy(string.find(resp, "application/json", 1, true))
        local _, body_start = string.find(resp, "\r\n\r\n", 1, true)
        local body2 = string.sub(resp, body_start + 1)
        local methods = Json.unpack(body2)
        local found_add = false
        for _, name in ipairs(methods) do
            if name == "add" then found_add = true end
        end
        assert.is_true(found_add)
    end)

    it("should not send data on closed connection", function()
        local sock, sent = helpers.mock_http_socket("")
        HttpTransport.serve(sock, dispatcher)
        assert.are.equal(0, #sent)
    end)

    it("should return 405 for unsupported HTTP method", function()
        local put_req = "PUT /api HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        local sock, sent = helpers.mock_http_socket(put_req)
        HttpTransport.serve(sock, dispatcher)
        local resp = table.concat(sent)
        assert.are.equal("HTTP/1.1 405", string.sub(resp, 1, 12))
    end)

    it("should return 413 when body exceeds max_body_len", function()
        local opts = { max_body_len = 10 }
        local http_req = "POST /api HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 100\r\n\r\n" .. string.rep("x", 100)
        local sock, sent = helpers.mock_http_socket(http_req)
        HttpTransport.serve(sock, dispatcher, nil, opts)
        local resp = table.concat(sent)
        assert.are.equal("HTTP/1.1 413", string.sub(resp, 1, 12))
        assert.truthy(string.find(resp, "body too large", 1, true))
    end)

    it("should return 400 when body is empty", function()
        local http_req = "POST /api HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n"
        local sock, sent = helpers.mock_http_socket(http_req)
        HttpTransport.serve(sock, dispatcher)
        local resp = table.concat(sent)
        assert.are.equal("HTTP/1.1 400", string.sub(resp, 1, 12))
        assert.truthy(string.find(resp, "empty body", 1, true))
    end)

    it("should return 400 when no Content-Length and no body", function()
        local http_req = "POST /api HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        local sock, sent = helpers.mock_http_socket(http_req)
        HttpTransport.serve(sock, dispatcher)
        local resp = table.concat(sent)
        assert.are.equal("HTTP/1.1 400", string.sub(resp, 1, 12))
    end)

    it("should return 500 when handle_message fails", function()
        local http_req = "POST /api HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 4\r\n\r\nbad!"
        local sock, sent = helpers.mock_http_socket(http_req)
        -- Save/restore packager.pack to avoid polluting shared singleton across tests
        local orig_pack = dispatcher.packager.pack
        dispatcher.packager.pack = function() error("encode error") end
        HttpTransport.serve(sock, dispatcher)
        dispatcher.packager.pack = orig_pack
        local resp = table.concat(sent)
        assert.are.equal("HTTP/1.1 500", string.sub(resp, 1, 12))
    end)
end)

describe("http transport serve_callback (callback mode)", function()
    local jp, dispatcher

    before_each(function()
        jp = Packager.get(Packager.JSON)
        dispatcher = Server.new({
            add = function(a, b) return a + b end,
        }).dispatcher
    end)

    it("should handle POST via callback", function()
        local req = Request.new({ method = "add", params = { 10, 20 }, provider = "p", token = "t" })
        local msg = Protocol.render(req, jp)
        local captured_status, captured_body
        local writer = function(status, _, body)
            captured_status = status
            captured_body = body
        end
        local ok = HttpTransport.serve_callback({ method = "POST", data = msg, writer = writer }, dispatcher)
        assert.is_true(ok)
        assert.are.equal(200, captured_status)
        local payload = Protocol.parse(captured_body, jp)
        assert.are.equal(30, payload.r)
    end)

    it("should return method list on GET via callback", function()
        local captured_status, captured_body
        local writer = function(status, _, body)
            captured_status = status
            captured_body = body
        end
        HttpTransport.serve_callback({ method = "GET", data = "", writer = writer }, dispatcher)
        assert.are.equal(200, captured_status)
        local methods = Json.unpack(captured_body)
        local found = false
        for _, name in ipairs(methods) do
            if name == "add" then found = true end
        end
        assert.is_true(found)
    end)

    it("should return 405 for PUT via callback", function()
        local captured_status
        local writer = function(status) captured_status = status end
        HttpTransport.serve_callback({ method = "PUT", data = "", writer = writer }, dispatcher)
        assert.are.equal(405, captured_status)
    end)

    it("should return 400 for empty body via callback", function()
        local captured_status
        local writer = function(status) captured_status = status end
        HttpTransport.serve_callback({ method = "POST", data = "", writer = writer }, dispatcher)
        assert.are.equal(400, captured_status)
    end)

    it("should return 413 for oversized body via callback", function()
        local captured_status, captured_body
        local writer = function(status, _, body) captured_status = status; captured_body = body end
        HttpTransport.serve_callback({ method = "POST", data = string.rep("x", 100),
            writer = writer }, dispatcher, { max_body_len = 10 })
        assert.are.equal(413, captured_status)
        assert.truthy(string.find(captured_body, "body too large", 1, true))
    end)

    it("should return 500 when handle_message fails via callback", function()
        local captured_status
        local writer = function(status) captured_status = status end
        -- Save/restore packager.pack to avoid polluting shared singleton across tests
        local orig_pack = dispatcher.packager.pack
        dispatcher.packager.pack = function() error("encode error") end
        HttpTransport.serve_callback({ method = "POST", data = "bad!", writer = writer }, dispatcher)
        dispatcher.packager.pack = orig_pack
        assert.are.equal(500, captured_status)
    end)

    it("should return nil, err when writer is not a function", function()
        local ok, err = HttpTransport.serve_callback(
            { method = "POST", data = "x", writer = "not a function" }, dispatcher)
        assert.is_nil(ok)
        assert.truthy(string.find(err, "writer"))
    end)

    it("should include Content-Length header in response", function()
        local req = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })
        local msg = Protocol.render(req, jp)
        local captured_headers
        local writer = function(_, headers) captured_headers = headers end
        HttpTransport.serve_callback({ method = "POST", data = msg, writer = writer }, dispatcher)
        assert.is_not_nil(captured_headers["Content-Length"])
    end)
end)

describe("http transport via Server Facade handle", function()
    local jp

    before_each(function()
        jp = Packager.get(Packager.JSON)
    end)

    it("should handle HTTP socket via server:handle", function()
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

    it("should handle HTTP callback via server:handle", function()
        local server = Server.new({ add = function(a, b) return a + b end })
        local req = Request.new({ method = "add", params = { 10, 20 }, provider = "p", token = "t" })
        local msg = Protocol.render(req, jp)
        local captured_status, captured_body
        local writer = function(status, _, body) captured_status = status; captured_body = body end
        local ok = server:handle({ method = "POST", data = msg, writer = writer })
        assert.is_true(ok)
        assert.are.equal(200, captured_status)
        local payload = Protocol.parse(captured_body, jp)
        assert.are.equal(30, payload.r)
    end)

    it("should respect max_body_len from server options in HTTP socket mode", function()
        local server = Server.new({ add = function() end }, { max_body_len = 10 })
        server.protocol = "http"
        local http_req = "POST /api HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n\r\n" .. string.rep("x", 100)
        local sock, sent = helpers.mock_http_socket(http_req)
        server:handle({ socket = sock })
        local resp = table.concat(sent)
        assert.are.equal("HTTP/1.1 413", string.sub(resp, 1, 12))
    end)
end)
