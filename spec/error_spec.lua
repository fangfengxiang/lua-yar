-- spec/error_spec.lua
-- Error 测试：categorization + code classification + error object

local Yar = require("yar")
local Server = Yar.server
local Client = Yar.client
local Error = Yar.error
local Packager = require("yar.packager.packager")
local Request = require("yar.message.request")
local Response = require("yar.message.response")
local Protocol = require("yar.protocol.protocol")

describe("error", function()
    local jp

    before_each(function()
        jp = Packager.get(Packager.JSON)
    end)

    describe("categorization", function()
        it("should return NOT_FOUND for unknown method", function()
            local server = Server.new({ add = function(a, b) return a + b end })
            local req = Request.new({ method = "nonexistent", params = {}, provider = "p", token = "t" })
            local resp = server.dispatcher:handle_message(Protocol.render(req, jp))
            local payload = Protocol.parse(resp, jp)
            assert.are.equal(Response.STATUS_ERROR, payload.s)
            assert.truthy(string.match(payload.e, "^method not found"))
        end)

        it("should return EXCEPTION for crashing method", function()
            local server = Server.new({ crash = function() error("boom") end })
            local req = Request.new({ method = "crash", params = {}, provider = "p", token = "t" })
            local resp = server.dispatcher:handle_message(Protocol.render(req, jp))
            local payload = Protocol.parse(resp, jp)
            assert.are.equal(Response.STATUS_ERROR, payload.s)
            assert.is_nil(string.match(payload.e, "^method not found"))
        end)
    end)

    describe("code classification", function()
        it("should return TRANSPORT or TIMEOUT for dead server", function()
            local client = Client.new("http://127.0.0.1:1/api")
            client:set_options({ timeout = 100, connect_timeout = 100 })
            local ret, err = client:call("add", {1, 2})
            assert.is_nil(ret)
            assert.is_not_nil(err)
            assert.truthy(err.code == Error.TRANSPORT or err.code == Error.TIMEOUT)
            assert.are.equal(err.message, tostring(err))
        end)
    end)

    describe("error object", function()
        it("should construct with code and message", function()
            local e = Error.new(Error.PROTOCOL, "bad packet")
            assert.are.equal(Error.PROTOCOL, e.code)
            assert.are.equal("bad packet", e.message)
            assert.are.equal("bad packet", tostring(e))
        end)

        it("should default message to empty string", function()
            local e2 = Error.new(Error.TRANSPORT)
            assert.are.equal("", e2.message)
            assert.are.equal("", tostring(e2))
        end)

        it("should expose all error code constants", function()
            assert.are.equal("TRANSPORT", Error.TRANSPORT)
            assert.are.equal("TIMEOUT", Error.TIMEOUT)
            assert.are.equal("PROTOCOL", Error.PROTOCOL)
            assert.are.equal("NOT_FOUND", Error.NOT_FOUND)
            assert.are.equal("EXCEPTION", Error.EXCEPTION)
        end)
    end)
end)
