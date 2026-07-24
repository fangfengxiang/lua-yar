-- spec/security_spec.lua
-- 安全边界测试：body edge + JSON nesting + method injection + func params + token truncation

local Yar = require("yar")
local Server = Yar.server
local Packager = require("yar.packager.packager")
local Json = require("yar.packager.json")
local Request = require("yar.message.request")
local Response = require("yar.message.response")
local Protocol = require("yar.protocol.protocol")
local Framing = require("yar.protocol.framing")
local Header = require("yar.protocol.header")
local Util = require("yar.util")

describe("security boundaries", function()
    local p

    before_each(function()
        p = Packager.get(Packager.JSON)
    end)

    describe("body length edge values", function()
        it("should pass when max == body_len", function()
            local req = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })
            local msg = Protocol.render(req, p)
            local header = Header.unpack(msg, Framing.HEADER_OFFSET)
            local body_len = header.body_len
            local ok = Framing.check_body_len(msg, body_len)
            assert.is_true(ok)
        end)

        it("should reject when max < body_len", function()
            local req = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })
            local msg = Protocol.render(req, p)
            local header = Header.unpack(msg, Framing.HEADER_OFFSET)
            local ok, err = Framing.check_body_len(msg, header.body_len - 1)
            assert.is_nil(ok)
            assert.truthy(string.find(err, "body too large"))
        end)

        it("should reject any body when max=0", function()
            local req = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })
            local msg = Protocol.render(req, p)
            local ok, err = Framing.check_body_len(msg, 0)
            assert.is_nil(ok)
            assert.truthy(string.find(err, "body too large"))
        end)
    end)

    describe("JSON deep nesting", function()
        for _, depth in ipairs({ 100, 500, 1000 }) do
            it("should not crash VM at depth " .. depth, function()
                local deep = string.rep('{"a":', depth) .. '1' .. string.rep('}', depth)
                -- unpack 对深度超限返回 nil, errmsg（不抛 error，不崩溃 VM）
                local result, _, err = Json.unpack(deep)
                -- 要么成功解码，要么返回深度超限错误
                assert.truthy(result or err)
            end)
        end
    end)

    describe("method name injection", function()
        for _, bad_method in ipairs({
            "add; DROP TABLE",
            "../etc/passwd",
            "",
            string.rep("A", 10000),
        }) do
            it("should return error for injected method", function()
                local server = Server.new({ add = function(a, b) return a + b end })
                local bad_req = Request.new({ method = bad_method, params = {}, provider = "p", token = "t" })
                local bad_msg = Protocol.render(bad_req, p)
                local resp = server.dispatcher:handle_message(bad_msg)
                assert.is_not_nil(resp)
                local payload = Protocol.parse(resp, p)
                assert.is_not_nil(payload)
                assert.are.equal(Response.STATUS_ERROR, payload.s)
            end)
        end
    end)

    describe("function params", function()
        it("should gracefully handle when params contain function", function()
            local func_req = Request.new({
                method = "add", params = { function() end, 2 },
                provider = "p", token = "t",
            })
            -- pack 对不支持的类型（function）编码为 null，不抛错（infallible）
            local msg = Protocol.render(func_req, p)
            assert.is_not_nil(msg)
            assert.are.equal("string", type(msg))
        end)
    end)

    describe("token/provider truncation", function()
        it("should pad short string to 32 bytes", function()
            local short = Util.pad_field("abc", 32)
            assert.are.equal(32, #short)
            assert.are.equal("abc", string.sub(short, 1, 3))
            assert.are.equal(0, string.byte(short, 4))
            assert.are.equal(0, string.byte(short, 32))
        end)

        it("should not pad exact-length string", function()
            local exact = Util.pad_field(string.rep("x", 32), 32)
            assert.are.equal(32, #exact)
            assert.is_nil(string.find(exact, "\0"))
        end)

        it("should truncate overlong string", function()
            local truncated = Util.pad_field(string.rep("T", 40), 32)
            assert.are.equal(32, #truncated)
            assert.are.equal(string.rep("T", 32), truncated)
        end)

        it("should trim trailing \\0", function()
            local padded = "hello" .. string.rep("\0", 27)
            assert.are.equal("hello", Util.trim_null(padded))
            assert.are.equal(5, #Util.trim_null(padded))
        end)

        it("should not modify string without trailing \\0", function()
            assert.are.equal("world", Util.trim_null("world"))
        end)

        it("should return empty string for all-\\0 input", function()
            assert.are.equal("", Util.trim_null(string.rep("\0", 10)))
        end)

        it("should truncate token/provider to 32 bytes in roundtrip", function()
            local h = Header.new({ id = 1, provider = string.rep("P", 50), token = string.rep("K", 50), body_len = 0 })
            local packed = h:pack()
            assert.are.equal(Header.SIZE, #packed)
            local h2 = Header.unpack(packed, 1)
            assert.are.equal(string.rep("P", 32), h2.provider)
            assert.are.equal(string.rep("K", 32), h2.token)
        end)
    end)
end)
