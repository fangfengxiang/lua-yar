-- spec/msgpack_spec.lua
-- Msgpack packager 测试：roundtrip + depth limit

local Msgpack = require("yar.packager.msgpack")
local Header = require("yar.protocol.header")
local Protocol = require("yar.protocol.protocol")
local Request = require("yar.message.request")
local Response = require("yar.message.response")
local Packager = require("yar.packager.packager")
local Util = require("yar.util")

describe("msgpack packager", function()
    describe("roundtrip", function()
        it("should pack and unpack basic types", function()
            local data = { i = 123456, m = "add", p = { 1, 2, 3 }, s = "你好", f = 3.14, b = true }
            local s = Msgpack.pack(data)
            local r = Msgpack.unpack(s)
            assert.are.equal(123456, r.i)
            assert.are.equal("add", r.m)
            assert.are.equal(2, r.p[2])
            assert.are.equal("你好", r.s)
            assert.are.equal(3.14, r.f)
            assert.is_true(r.b)
        end)
    end)

    describe("integer encoding boundaries", function()
        it("should pack positive fixint (0-0x7f)", function()
            assert.are.equal(0, Msgpack.unpack(Msgpack.pack(0)))
            assert.are.equal(0x7f, Msgpack.unpack(Msgpack.pack(0x7f)))
        end)

        it("should pack uint8 (0x80-0xff)", function()
            assert.are.equal(0x80, Msgpack.unpack(Msgpack.pack(0x80)))
            assert.are.equal(0xff, Msgpack.unpack(Msgpack.pack(0xff)))
            -- verify prefix byte
            assert.are.equal(0xcc, string.byte(Msgpack.pack(0x80), 1))
        end)

        it("should pack uint16 (0x100-0xffff)", function()
            assert.are.equal(0x100, Msgpack.unpack(Msgpack.pack(0x100)))
            assert.are.equal(0xffff, Msgpack.unpack(Msgpack.pack(0xffff)))
            assert.are.equal(0xcd, string.byte(Msgpack.pack(0x100), 1))
        end)

        it("should pack uint32 (0x10000-0xffffffff)", function()
            assert.are.equal(0x10000, Msgpack.unpack(Msgpack.pack(0x10000)))
            assert.are.equal(0xffffffff, Msgpack.unpack(Msgpack.pack(0xffffffff)))
            assert.are.equal(0xce, string.byte(Msgpack.pack(0x10000), 1))
        end)

        it("should pack uint64 (> 0xffffffff, up to 2^53)", function()
            local n = 0x100000000      -- 2^32
            assert.are.equal(n, Msgpack.unpack(Msgpack.pack(n)))
            assert.are.equal(0xcf, string.byte(Msgpack.pack(n), 1))
            local n2 = 0x1ffffffff    -- 2^33 - 1
            assert.are.equal(n2, Msgpack.unpack(Msgpack.pack(n2)))
        end)
    end)

    describe("negative integer encoding boundaries", function()
        it("should pack negative fixint (-32 to -1)", function()
            assert.are.equal(-1, Msgpack.unpack(Msgpack.pack(-1)))
            assert.are.equal(-32, Msgpack.unpack(Msgpack.pack(-32)))
        end)

        it("should pack int8 (-128 to -33)", function()
            assert.are.equal(-33, Msgpack.unpack(Msgpack.pack(-33)))
            assert.are.equal(-128, Msgpack.unpack(Msgpack.pack(-128)))
            assert.are.equal(0xd0, string.byte(Msgpack.pack(-33), 1))
        end)

        it("should pack int16 (-32768 to -129)", function()
            assert.are.equal(-129, Msgpack.unpack(Msgpack.pack(-129)))
            assert.are.equal(-32768, Msgpack.unpack(Msgpack.pack(-32768)))
            assert.are.equal(0xd1, string.byte(Msgpack.pack(-129), 1))
        end)

        it("should pack int32 (-2147483648 to -32769)", function()
            assert.are.equal(-32769, Msgpack.unpack(Msgpack.pack(-32769)))
            assert.are.equal(-2147483648, Msgpack.unpack(Msgpack.pack(-2147483648)))
            assert.are.equal(0xd2, string.byte(Msgpack.pack(-32769), 1))
        end)

        it("should pack int64 (< -2147483648)", function()
            local n = -2147483649
            assert.are.equal(n, Msgpack.unpack(Msgpack.pack(n)))
            assert.are.equal(0xd3, string.byte(Msgpack.pack(n), 1))
        end)
    end)

    describe("double encoding", function()
        it("should pack and roundtrip normal double", function()
            assert.are.equal(3.14, Msgpack.unpack(Msgpack.pack(3.14)))
            assert.are.equal(-2.5, Msgpack.unpack(Msgpack.pack(-2.5)))
        end)

        it("should pack zero", function()
            assert.are.equal(0, Msgpack.unpack(Msgpack.pack(0)))
            -- 0 是整数，编码为 positive fixint 0x00（非 float64）
            assert.are.equal(0x00, string.byte(Msgpack.pack(0), 1))
        end)

        it("should pack NaN", function()
            local nan = 0 / 0
            local r = Msgpack.unpack(Msgpack.pack(nan))
            assert.is_true(r ~= r)  -- NaN check
            assert.are.equal(0xcb, string.byte(Msgpack.pack(nan), 1))
        end)

        it("should pack positive infinity", function()
            local r = Msgpack.unpack(Msgpack.pack(math.huge))
            assert.are.equal(math.huge, r)
            assert.are.equal(0xcb, string.byte(Msgpack.pack(math.huge), 1))
        end)

        it("should pack negative infinity", function()
            local r = Msgpack.unpack(Msgpack.pack(-math.huge))
            assert.are.equal(-math.huge, r)
            -- IEEE754: -Inf = 0xFFF0000000000000（符号位=1，指数=0x7FF，尾数=0）
            assert.are.equal(0xcb, string.byte(Msgpack.pack(-math.huge), 1))
            assert.are.equal(0xff, string.byte(Msgpack.pack(-math.huge), 2))
        end)
    end)

    describe("string encoding boundaries", function()
        it("should pack fixstr (<= 31 chars)", function()
            local s = string.rep("a", 31)
            assert.are.equal(s, Msgpack.unpack(Msgpack.pack(s)))
        end)

        it("should pack str8 (32-255 chars)", function()
            local s = string.rep("b", 255)
            assert.are.equal(s, Msgpack.unpack(Msgpack.pack(s)))
            assert.are.equal(0xd9, string.byte(Msgpack.pack(s), 1))
        end)

        it("should pack str16 (256-65535 chars)", function()
            local s = string.rep("c", 256)
            assert.are.equal(s, Msgpack.unpack(Msgpack.pack(s)))
            assert.are.equal(0xda, string.byte(Msgpack.pack(s), 1))
            local s2 = string.rep("d", 65535)
            assert.are.equal(s2, Msgpack.unpack(Msgpack.pack(s2)))
        end)

        it("should pack str32 (>= 65536 chars)", function()
            local s = string.rep("e", 65536)
            assert.are.equal(s, Msgpack.unpack(Msgpack.pack(s)))
            assert.are.equal(0xdb, string.byte(Msgpack.pack(s), 1))
        end)
    end)

    describe("table encoding boundaries", function()
        it("should pack empty array as fixarray(0)", function()
            local s = Msgpack.pack({})
            assert.are.equal(0x90, string.byte(s, 1))
            local r = Msgpack.unpack(s)
            assert.are.equal(0, #r)
        end)

        it("should pack fixarray (1-15 elements)", function()
            local t = { 10, 20, 30 }
            local r = Msgpack.unpack(Msgpack.pack(t))
            assert.are.equal(3, #r)
            assert.are.equal(20, r[2])
        end)

        it("should pack array16 (17 elements)", function()
            local t = {}
            for i = 1, 17 do t[i] = i end
            local s = Msgpack.pack(t)
            assert.are.equal(0xdc, string.byte(s, 1))
            local r = Msgpack.unpack(s)
            assert.are.equal(17, #r)
            assert.are.equal(17, r[17])
        end)

        it("should pack array32 (65536 elements)", function()
            local t = {}
            for i = 1, 65536 do t[i] = i end
            local s = Msgpack.pack(t)
            assert.are.equal(0xdd, string.byte(s, 1))
            local r = Msgpack.unpack(s)
            assert.are.equal(65536, #r)
            assert.are.equal(65536, r[65536])
        end)

        it("should pack fixmap (1-15 pairs)", function()
            local t = { a = 1, b = 2 }
            local r = Msgpack.unpack(Msgpack.pack(t))
            assert.are.equal(1, r.a)
            assert.are.equal(2, r.b)
        end)

        it("should pack map16 (17 pairs)", function()
            local t = {}
            for i = 1, 17 do t["k" .. i] = i end
            local s = Msgpack.pack(t)
            assert.are.equal(0xde, string.byte(s, 1))
            local r = Msgpack.unpack(s)
            assert.are.equal(17, r.k17)
        end)

        it("should pack map32 (65536 pairs)", function()
            local t = {}
            for i = 1, 65536 do t["k" .. i] = i end
            local s = Msgpack.pack(t)
            assert.are.equal(0xdf, string.byte(s, 1))
            local r = Msgpack.unpack(s)
            assert.are.equal(65536, r["k65536"])
        end)
    end)

    describe("nil and boolean encoding", function()
        it("should pack and unpack nil", function()
            assert.is_nil(Msgpack.unpack(Msgpack.pack(nil)))
            assert.are.equal(0xc0, string.byte(Msgpack.pack(nil), 1))
        end)

        it("should pack and unpack true/false", function()
            assert.is_true(Msgpack.unpack(Msgpack.pack(true)))
            assert.is_false(Msgpack.unpack(Msgpack.pack(false)))
            assert.are.equal(0xc3, string.byte(Msgpack.pack(true), 1))
            assert.are.equal(0xc2, string.byte(Msgpack.pack(false), 1))
        end)
    end)

    describe("depth limit", function()
        local original

        before_each(function()
            original = Msgpack.max_depth
        end)

        after_each(function()
            Msgpack.set_max_depth(original)
        end)

        it("should decode normal depth (3 levels)", function()
            local data = Msgpack.unpack(Msgpack.pack({ { { 1 } } }))
            assert.are.equal(1, data[1][1][1])
        end)

        it("should error when array depth exceeds max_depth", function()
            Msgpack.set_max_depth(10)
            local deep = string.rep(string.char(0x91), 11) .. string.char(0x01)
            local result, err = Msgpack.unpack(deep)
            assert.is_nil(result)
            assert.truthy(string.find(err, "depth limit exceeded"))
        end)

        it("should pass at exactly max_depth", function()
            Msgpack.set_max_depth(10)
            local at_limit = string.rep(string.char(0x91), 10) .. string.char(0x01)
            local result = Msgpack.unpack(at_limit)
            assert.are.equal(1, result[1][1][1][1][1][1][1][1][1][1])
        end)

        it("should limit map nesting depth", function()
            Msgpack.set_max_depth(10)
            local map_prefix = string.char(0x81) .. string.char(0xa1) .. "a"
            local deep_map = string.rep(map_prefix, 11) .. string.char(0x01)
            local result, err = Msgpack.unpack(deep_map)
            assert.is_nil(result)
            assert.truthy(string.find(err, "depth limit exceeded"))
        end)

        it("should route msgpack_max_depth via Yar.set_options", function()
            local Yar = require("yar")
            Yar.set_options({ packager = { msgpack_max_depth = 5 } })
            assert.are.equal(5, Msgpack.max_depth)
        end)

        it("should return error response for deep msgpack via handle_message", function()
            local Yar = require("yar")
            local Server = Yar.server
            Msgpack.set_max_depth(5)
            local server = Server.new({ add = function(a, b) return a + b end })
            local p = Packager.get(Packager.MSGPACK)
            local req = Request.new({ method = "add", params = {}, provider = "p", token = "t" })
            local deep_body = string.rep(string.char(0x91), 6) .. string.char(0x01)
            local header = Header.new({ id = req.id, provider = "p", token = "t", body_len = #deep_body })
            local msg = Util.pad_field("MSGPACK", 8) .. header:pack() .. deep_body
            local resp = server.dispatcher:handle_message(msg)
            assert.is_not_nil(resp)
            local payload = Protocol.parse(resp, p)
            assert.are.equal(Response.STATUS_ERROR, payload.s)
        end)

        it("should error when encode depth exceeds max_depth (circular reference)", function()
            Msgpack.set_max_depth(10)
            local t = {}
            t.self = t  -- 循环引用
            local ok, err = pcall(Msgpack.pack, t)
            assert.is_false(ok)
            assert.truthy(string.find(err, "encode depth limit exceeded", 1, true))
        end)

        it("should error when encode depth exceeds max_depth (deep nesting)", function()
            Msgpack.set_max_depth(5)
            local deep = { 1 }
            for _ = 1, 10 do
                deep = { deep }
            end
            local ok, err = pcall(Msgpack.pack, deep)
            assert.is_false(ok)
            assert.truthy(string.find(err, "encode depth limit exceeded", 1, true))
        end)

        it("should encode normal shallow table without error", function()
            Msgpack.set_max_depth(10)
            local data = { a = 1, b = { c = { d = "hello" } } }
            local s = Msgpack.pack(data)
            local r = Msgpack.unpack(s)
            assert.are.equal(1, r.a)
            assert.are.equal("hello", r.b.c.d)
        end)
    end)
end)
