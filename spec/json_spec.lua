-- spec/json_spec.lua
-- JSON packager 测试：roundtrip + surrogate pair + depth limit

local Json = require("yar.packager.json")
local Header = require("yar.protocol.header")
local Protocol = require("yar.protocol.protocol")
local Request = require("yar.message.request")
local Response = require("yar.message.response")
local Packager = require("yar.packager.packager")
local Util = require("yar.util")

describe("json packager", function()
    describe("roundtrip", function()
        it("should pack and unpack basic types", function()
            local data = { a = 1, b = "hello", c = { 1, 2, 3 }, d = true, e = nil }
            local s = Json.pack(data)
            local r = Json.unpack(s)
            assert.are.equal(1, r.a)
            assert.are.equal("hello", r.b)
            assert.are.equal(2, r.c[2])
            assert.is_true(r.d)
        end)
    end)

    describe("surrogate pair", function()
        it("should decode surrogate pair to UTF-8", function()
            local s = '{"name":"\\uD834\\uDD1E"}'
            local r = Json.unpack(s)
            local expected = string.char(0xF0, 0x9D, 0x84, 0x9E)
            assert.are.equal(expected, r.name)
        end)

        it("should decode BMP unicode escape", function()
            local s2 = '{"cur":"\\u20AC"}'
            local r2 = Json.unpack(s2)
            assert.are.equal(string.char(0xE2, 0x82, 0xAC), r2.cur)
        end)

        it("should not crash on isolated high surrogate", function()
            local s3 = '{"x":"\\uD834"}'
            local r3 = Json.unpack(s3)
            assert.is_not_nil(r3.x)
        end)
    end)

    describe("depth limit", function()
        local original

        before_each(function()
            original = Json.max_depth
        end)

        after_each(function()
            Json.set_max_depth(original)
        end)

        it("should decode normal depth (3 levels)", function()
            local data = Json.decode('{"a":{"b":{"c":1}}}')
            assert.are.equal(1, data.a.b.c)
        end)

        it("should error when depth exceeds max_depth", function()
            Json.set_max_depth(10)
            local deep = string.rep("[", 11) .. "1" .. string.rep("]", 11)
            local result, _, err = Json.decode(deep)
            assert.is_nil(result)
            assert.truthy(string.find(err, "depth limit exceeded"))
        end)

        it("should pass at exactly max_depth", function()
            Json.set_max_depth(10)
            local at_limit = string.rep("[", 10) .. "1" .. string.rep("]", 10)
            local result = Json.decode(at_limit)
            assert.are.equal(1, result[1][1][1][1][1][1][1][1][1][1])
        end)

        it("should limit object nesting depth", function()
            Json.set_max_depth(10)
            local deep_obj = '{"a":' .. string.rep('{"a":', 11) .. '1' .. string.rep('}', 11) .. '}'
            local result, _, err = Json.decode(deep_obj)
            assert.is_nil(result)
            assert.truthy(string.find(err, "depth limit exceeded"))
        end)

        it("should route json_max_depth via Yar.set_options", function()
            local Yar = require("yar")
            Yar.set_options({ packager = { json_max_depth = 5 } })
            assert.are.equal(5, Json.max_depth)
        end)

        it("should return error response for deep JSON via handle_message", function()
            local Yar = require("yar")
            local Server = Yar.server
            Json.set_max_depth(5)
            local server = Server.new({ add = function(a, b) return a + b end })
            local p = Packager.get(Packager.JSON)
            local req = Request.new({ method = "add", params = {}, provider = "p", token = "t" })
            local deep_body = string.rep("[", 6) .. "1" .. string.rep("]", 6)
            local header = Header.new({ id = req.id, provider = "p", token = "t", body_len = #deep_body })
            local msg = Util.pad_field("JSON", 8) .. header:pack() .. deep_body
            local resp = server.dispatcher:handle_message(msg)
            assert.is_not_nil(resp)
            local payload = Protocol.parse(resp, p)
            assert.are.equal(Response.STATUS_ERROR, payload.s)
        end)

        it("should error when encode depth exceeds max_depth (circular reference)", function()
            Json.set_max_depth(10)
            local t = {}
            t.self = t  -- 循环引用
            local ok, err = pcall(Json.pack, t)
            assert.is_false(ok)
            assert.truthy(string.find(err, "encode depth limit exceeded", 1, true))
        end)

        it("should error when encode depth exceeds max_depth (deep nesting)", function()
            Json.set_max_depth(5)
            local deep = { 1 }
            for _ = 1, 10 do
                deep = { deep }
            end
            local ok, err = pcall(Json.pack, deep)
            assert.is_false(ok)
            assert.truthy(string.find(err, "encode depth limit exceeded", 1, true))
        end)

        it("should encode normal shallow table without error", function()
            Json.set_max_depth(10)
            local data = { a = 1, b = { c = { d = "hello" } } }
            local s = Json.pack(data)
            local r = Json.unpack(s)
            assert.are.equal(1, r.a)
            assert.are.equal("hello", r.b.c.d)
        end)
    end)

    describe("malformed literals", function()
        it("should reject truncated true", function()
            local result, _, err = Json.decode("tru")
            assert.is_nil(result)
            assert.truthy(string.find(err, "invalid literal"))
        end)

        it("should reject malformed true", function()
            local result, _, err = Json.decode("truu")
            assert.is_nil(result)
            assert.truthy(string.find(err, "invalid literal"))
        end)

        it("should reject truncated false", function()
            local result, _, err = Json.decode("fals")
            assert.is_nil(result)
            assert.truthy(string.find(err, "invalid literal"))
        end)

        it("should reject truncated null", function()
            local result, _, err = Json.decode("nul")
            assert.is_nil(result)
            assert.truthy(string.find(err, "invalid literal"))
        end)

        it("should accept valid true/false/null", function()
            assert.is_true(Json.decode("true"))
            assert.is_false(Json.decode("false"))
            assert.is_nil(Json.decode("null"))
        end)
    end)

    describe("encode — string escaping", function()
        it("should escape double quote", function()
            assert.are.equal('"hello\\"world"', Json.pack('hello"world'))
        end)

        it("should escape backslash", function()
            assert.are.equal('"hello\\\\world"', Json.pack('hello\\world'))
        end)

        it("should escape newline", function()
            assert.are.equal('"hello\\nworld"', Json.pack('hello\nworld'))
        end)

        it("should escape carriage return", function()
            assert.are.equal('"hello\\rworld"', Json.pack('hello\rworld'))
        end)

        it("should escape tab", function()
            assert.are.equal('"hello\\tworld"', Json.pack('hello\tworld'))
        end)

        it("should escape backspace", function()
            assert.are.equal('"hello\\bworld"', Json.pack('hello\bworld'))
        end)

        it("should escape form feed", function()
            assert.are.equal('"hello\\fworld"', Json.pack('hello\fworld'))
        end)

        it("should escape control characters as \\uXXXX", function()
            local s = string.char(0x01)
            local encoded = Json.pack(s)
            assert.truthy(string.find(encoded, '\\u0001'))
        end)

        it("should not escape normal printable characters", function()
            assert.are.equal('"hello world 123"', Json.pack('hello world 123'))
        end)

        it("should roundtrip escaped strings", function()
            local data = { msg = 'a"b\\c\nd\te' }
            local s = Json.pack(data)
            local r = Json.unpack(s)
            assert.are.equal(data.msg, r.msg)
        end)
    end)

    describe("encode — number edge cases", function()
        it("should encode NaN as null", function()
            local nan = math.huge - math.huge
            assert.are.equal("null", Json.pack(nan))
        end)

        it("should encode positive infinity as null", function()
            assert.are.equal("null", Json.pack(math.huge))
        end)

        it("should encode negative infinity as null", function()
            assert.are.equal("null", Json.pack(-math.huge))
        end)

        it("should encode float with decimal", function()
            local s = Json.pack(3.14)
            local r = Json.unpack(s)
            assert.are.equal(3.14, r)
        end)

        it("should encode large integer", function()
            local s = Json.pack(1000000)
            assert.are.equal("1000000", s)
        end)
    end)

    describe("encode — table edge cases", function()
        it("should encode empty table as []", function()
            assert.are.equal("[]", Json.pack({}))
        end)

        it("should encode table with non-integer keys as object", function()
            local s = Json.pack({ name = "test", value = 42 })
            local r = Json.unpack(s)
            assert.are.equal("test", r.name)
            assert.are.equal(42, r.value)
        end)

    it("should encode mixed table (non-integer key → object)", function()
        local s = Json.pack({ 1, 2, name = "x" })
        local r = Json.unpack(s)
        -- 混合表编码为 JSON 对象，key 均为字符串
        assert.are.equal(1, r["1"])
        assert.are.equal(2, r["2"])
        assert.are.equal("x", r.name)
    end)

        it("should encode nested empty object", function()
            local s = Json.pack({ a = {} })
            local r = Json.unpack(s)
            assert.are.equal("[]", Json.pack(r.a))
        end)

        it("should encode function as null", function()
            local s = Json.pack({ fn = function() end })
            local r = Json.unpack(s)
            assert.is_nil(r.fn)
        end)
    end)

    describe("decode — error paths", function()
        it("should reject unterminated string", function()
            local result, _, err = Json.decode('{"key":"unterminated')
            assert.is_nil(result)
            assert.truthy(string.find(err, "unterminated string"))
        end)

        it("should reject unterminated string after backslash at end", function()
            local result, _, err = Json.decode('"abc\\')
            assert.is_nil(result)
            assert.truthy(string.find(err, "unterminated string"))
        end)

        it("should reject invalid number", function()
            local result, _, err = Json.decode("--1")
            assert.is_nil(result)
            assert.truthy(string.find(err, "invalid number"))
        end)

        it("should reject unexpected end of input", function()
            local result, _, err = Json.decode("")
            assert.is_nil(result)
            assert.truthy(string.find(err, "unexpected end of input"))
        end)

        it("should reject trailing content", function()
            local result, _, err = Json.decode('1 2 3')
            assert.is_nil(result)
            assert.truthy(string.find(err, "trailing content"))
        end)

        it("should reject expected , or ] in array", function()
            local result, _, err = Json.decode('[1 2]')
            assert.is_nil(result)
            assert.truthy(string.find(err, "expected , or ]"))
        end)

        it("should reject empty object without closing brace", function()
            local result, _, err = Json.decode('{')
            assert.is_nil(result)
            assert.truthy(err)
        end)

        it("should reject expected : in object", function()
            local result, _, err = Json.decode('{"key" 1}')
            assert.is_nil(result)
            assert.truthy(string.find(err, "expected :"))
        end)

        it("should reject expected , or } in object", function()
            local result, _, err = Json.decode('{"a":1 2}')
            assert.is_nil(result)
            assert.truthy(string.find(err, "expected , or }"))
        end)
    end)

    describe("decode — string escape sequences", function()
        it("should decode all standard escapes", function()
            local r = Json.unpack('"\\n\\t\\r\\b\\f\\"\\\\\\/"')
            assert.are.equal('\n\t\r\b\f"\\/', r)
        end)

        it("should decode unknown escape as literal char", function()
            local r = Json.unpack('"\\x"')
            assert.are.equal("x", r)
        end)

        it("should decode empty string", function()
            local r = Json.unpack('""')
            assert.are.equal("", r)
        end)

        it("should decode string with no escapes (single segment)", function()
            local r = Json.unpack('"hello world"')
            assert.are.equal("hello world", r)
        end)

        it("should decode multi-segment string (escape + plain)", function()
            local r = Json.unpack('"hello\\nworld"')
            assert.are.equal("hello\nworld", r)
        end)

        it("should decode string with multiple segments requiring concat", function()
            local r = Json.unpack('"a\\nb\\nc\\nd"')
            assert.are.equal("a\nb\nc\nd", r)
        end)
    end)

    describe("decode — whitespace handling", function()
        it("should skip whitespace before value", function()
            assert.are.equal(1, Json.decode("  1  "))
        end)

        it("should skip whitespace in array", function()
            local r = Json.decode("[ 1 , 2 , 3 ]")
            assert.are.equal(3, r[3])
        end)

        it("should skip whitespace in object", function()
            local r = Json.decode('{ "a" : 1 , "b" : 2 }')
            assert.are.equal(1, r.a)
            assert.are.equal(2, r.b)
        end)
    end)

    describe("decode — unicode", function()
        it("should decode ASCII unicode escape (code < 0x80)", function()
            local r = Json.unpack('"\\u0041"')
            assert.are.equal("A", r)
        end)

        it("should decode 2-byte UTF-8 (code < 0x800)", function()
            -- U+00A9 © → 2-byte UTF-8
            local r = Json.unpack('"\\u00A9"')
            assert.are.equal(string.char(0xC2, 0xA9), r)
        end)

        it("should decode 3-byte UTF-8 (code < 0x10000)", function()
            -- U+20AC € → 3-byte UTF-8
            local r = Json.unpack('"\\u20AC"')
            assert.are.equal(string.char(0xE2, 0x82, 0xAC), r)
        end)

        it("should decode 4-byte UTF-8 (surrogate pair, code >= 0x10000)", function()
            -- U+1D11E 𝄞 → 4-byte UTF-8
            local r = Json.unpack('"\\uD834\\uDD1E"')
            assert.are.equal(string.char(0xF0, 0x9D, 0x84, 0x9E), r)
        end)

        it("should handle isolated high surrogate without low surrogate", function()
            local r = Json.unpack('"\\uD834"')
            assert.is_not_nil(r)
        end)

        it("should handle high surrogate followed by non-surrogate", function()
            local r = Json.unpack('"\\uD834\\u0041"')
            assert.is_not_nil(r)
        end)
    end)

    describe("decode — number parsing", function()
        it("should parse negative number", function()
            assert.are.equal(-42, Json.decode("-42"))
        end)

        it("should parse float", function()
            assert.are.equal(3.14, Json.decode("3.14"))
        end)

        it("should parse exponential notation", function()
            local r = Json.decode("1e2")
            assert.are.equal(100, r)
        end)

        it("should parse capital E exponential", function()
            local r = Json.decode("1E2")
            assert.are.equal(100, r)
        end)

        it("should parse number with + prefix (lenient)", function()
            local r = Json.decode("+42")
            assert.are.equal(42, r)
        end)
    end)

    describe("decode — arrays and objects", function()
        it("should decode empty array", function()
            local r = Json.decode("[]")
            assert.are.equal(0, #r)
        end)

        it("should decode array with multiple elements", function()
            local r = Json.decode("[1,2,3,4,5]")
            assert.are.equal(5, #r)
            assert.are.equal(3, r[3])
        end)

        it("should decode nested arrays", function()
            local r = Json.decode("[[1,2],[3,4]]")
            assert.are.equal(2, r[1][2])
            assert.are.equal(4, r[2][2])
        end)

        it("should decode empty object", function()
            local r = Json.decode("{}")
            assert.is_truthy(next(r) == nil)
        end)

        it("should decode object with multiple keys", function()
            local r = Json.decode('{"a":1,"b":2,"c":3}')
            assert.are.equal(1, r.a)
            assert.are.equal(2, r.b)
            assert.are.equal(3, r.c)
        end)

        it("should decode nested objects", function()
            local r = Json.decode('{"outer":{"inner":"value"}}')
            assert.are.equal("value", r.outer.inner)
        end)
    end)
end)
