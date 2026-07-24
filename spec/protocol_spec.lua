-- spec/protocol_spec.lua
-- 协议渲染/解析往返测试：JSON + Msgpack

local Packager = require("yar.packager.packager")
local Request = require("yar.message.request")
local Response = require("yar.message.response")
local Protocol = require("yar.protocol.protocol")

describe("protocol render/parse roundtrip", function()
    describe("JSON packager", function()
        it("should roundtrip request and response", function()
            local p = Packager.get(Packager.JSON)
            local req = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })
            local msg = Protocol.render(req, p)
            local payload, header = Protocol.parse(msg, p)
            assert.are.equal("add", payload.m)
            assert.are.equal(1, payload.p[1])
            assert.are.equal(req.id, header.id)
            assert.are.equal("p", header.provider)
            assert.are.equal("t", header.token)

            local resp = Response.new({ id = req.id }):set_retval(3)
            local rmsg = Protocol.render(resp, p)
            local rpayload, rheader = Protocol.parse(rmsg, p)
            assert.are.equal(3, rpayload.r)
            assert.are.equal(0, rpayload.s)
            assert.are.equal(req.id, rheader.id)
        end)
    end)

    describe("Msgpack packager", function()
        it("should roundtrip request and response", function()
            local mp = Packager.get(Packager.MSGPACK)
            local req = Request.new({ method = "echo", params = { "hi", 42 }, provider = "p2", token = "t2" })
            local msg = Protocol.render(req, mp)
            local payload, header = Protocol.parse(msg, mp)
            assert.are.equal("echo", payload.m)
            assert.are.equal("hi", payload.p[1])
            assert.are.equal("p2", header.provider)

            local resp = Response.new({ id = req.id }):set_retval({ ok = true })
            local rmsg = Protocol.render(resp, mp)
            local rpayload, rheader = Protocol.parse(rmsg, mp)
            assert.is_true(rpayload.r.ok)
            assert.are.equal(req.id, rheader.id)
        end)
    end)

    describe("third-party packager injection (duck typing)", function()
        it("should catch error() from injected packager.pack via boundary pcall", function()
            -- 模拟 cjson.encode 对循环引用抛 error() 的行为
            -- render 内部不 pcall（ADR #37 修正），error() 传播到调用方边界
            local fake_packager = {
                name = "FAKE",
                pack = function(_)
                    error("Cannot serialise cyclic recursive table")
                end,
                unpack = function(_)
                    return nil, "fake unpack error"
                end,
            }
            local req = Request.new({ method = "test", params = {}, provider = "p", token = "t" })
            -- 调用方在边界处 pcall 捕获（与 dispatcher safe_render / client:call 一致）
            local ok, err = pcall(Protocol.render, req, fake_packager)
            assert.is_false(ok)
            assert.truthy(string.find(err, "Cannot serialise", 1, true))
        end)
    end)
end)
