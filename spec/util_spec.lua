-- spec/util_spec.lua
-- Util 测试：gen_id + token/provider truncation

local Request = require("yar.message.request")
local Util = require("yar.util")
local Header = require("yar.protocol.header")

describe("util", function()
    describe("gen_id", function()
        it("should generate unique IDs within uint32 range", function()
            local seen = {}
            for _ = 1, 1000 do
                local id = Request.gen_id()
                assert.truthy(id >= 0 and id <= 0xFFFFFFFF)
                assert.is_false(seen[id] ~= nil)
                seen[id] = true
            end
        end)

        it("should not call math.randomseed", function()
            local original_randomseed = math.randomseed -- luacheck: ignore
            local seeded = false
            math.randomseed = function() seeded = true end -- luacheck: ignore
            local ok, id = pcall(Request.gen_id)
            math.randomseed = original_randomseed -- luacheck: ignore
            assert.is_true(ok)
            assert.is_false(seeded)
            assert.truthy(id >= 0 and id <= 0xFFFFFFFF)
        end)

        it("should support set_id_generator injection and reset", function()
            local called = false
            Request.set_id_generator(function() called = true; return 12345 end)
            local id = Request.gen_id()
            assert.is_true(called)
            assert.are.equal(12345, id)

            Request.set_id_generator(function() return 0xFFFFFFFF end)
            assert.are.equal(0xFFFFFFFF, Request.gen_id())

            local ok = pcall(Request.set_id_generator, "not a function")
            assert.is_false(ok)

            Request.set_id_generator(nil)
            local id2 = Request.gen_id()
            assert.truthy(id2 >= 0 and id2 <= 0xFFFFFFFF)
        end)

        it("should support seed convenience function", function()
            local id = Request.gen_id()
            assert.truthy(id >= 0 and id <= 0xFFFFFFFF)

            local seed_called = false
            Request.seed(function() seed_called = true; math.randomseed(os.time()) end)
            assert.is_true(seed_called)
            local id2 = Request.gen_id()
            assert.truthy(id2 >= 0 and id2 <= 0xFFFFFFFF)

            local ok = pcall(Request.seed, "not a function")
            assert.is_false(ok)

            Request.set_id_generator(nil)
        end)
    end)

    describe("pad_field / trim_null", function()
        it("should pad short string to target length with \\0", function()
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
            local long_token = string.rep("T", 40)
            local truncated = Util.pad_field(long_token, 32)
            assert.are.equal(32, #truncated)
            assert.are.equal(string.rep("T", 32), truncated)
        end)

        it("should trim trailing \\0", function()
            local padded = "hello" .. string.rep("\0", 27)
            local trimmed = Util.trim_null(padded)
            assert.are.equal("hello", trimmed)
            assert.are.equal(5, #trimmed)
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
