-- test/json_boundary.lua
-- JSON 编解码边界测试（独立脚本，无 busted 依赖）
-- 运行：lua test/json_boundary.lua   或   luajit test/json_boundary.lua
-- 覆盖：空串、纯串、转义字符（" \ / \n \t \r \b \f）、控制字符 \uXXXX、
--       UTF-16 代理对、未闭合字符串、混合转义+普通、深度控制、
--       DEL/高字节/无效转义/尾部垃圾/空输入/连续转义/孤立代理对

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local Json = require("yar.packager.json")

-- 用 string.char 构造控制字符，避免 \x 转义（Lua 5.1 不支持 \xNN）
local C01  = string.char(0x01)
local C1F  = string.char(0x1F)
local C7F  = string.char(0x7F)
local C80  = string.char(0x80)
local CFF  = string.char(0xFF)
-- U+1D11E (𝄞) 的 UTF-8 编码：F0 9D 84 9E
local SURROGATE_UTF8 = string.char(0xF0, 0x9D, 0x84, 0x9E)

local pass = 0
local fail = 0
local failures = {}

local function eq(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) == "table" then
        for k, v in pairs(a) do
            if not eq(v, b[k]) then return false end
        end
        for k in pairs(b) do
            if a[k] == nil then return false end
        end
        return true
    end
    return a == b
end

local function check(desc, got, expected)
    if eq(got, expected) then
        pass = pass + 1
    else
        fail = fail + 1
        table.insert(failures, string.format("FAIL: %s\n  expected: %q\n  got:      %q",
            desc, tostring(expected), tostring(got)))
    end
end

local function check_err(desc, fn, err_sub)
    local ok, err = pcall(fn)
    if not ok and err_sub and string.find(err, err_sub, 1, true) then
        pass = pass + 1
    elseif ok then
        fail = fail + 1
        table.insert(failures, "FAIL: " .. desc .. " (expected error, got success)")
    else
        fail = fail + 1
        table.insert(failures, string.format("FAIL: %s\n  expected err containing: %q\n  got: %q",
            desc, err_sub, tostring(err)))
    end
end

----------------------------------------------------------------------
-- encode_string 边界
----------------------------------------------------------------------
check("encode empty",        Json.pack(""),           '""')
check("encode plain",        Json.pack("hello"),      '"hello"')
check("encode quote",        Json.pack('a"b'),        '"a\\"b"')
check("encode backslash",    Json.pack('a\\b'),       '"a\\\\b"')
check("encode slash",         Json.pack('a/b'),        '"a/b"')      -- / 不转义
check("encode newline",      Json.pack("a\nb"),       '"a\\nb"')
check("encode tab",          Json.pack("a\tb"),       '"a\\tb"')
check("encode cr",           Json.pack("a\rb"),       '"a\\rb"')
check("encode backspace",    Json.pack("a\bb"),       '"a\\bb"')
check("encode formfeed",     Json.pack("a\fb"),       '"a\\fb"')
check("encode ctrl 0x01",    Json.pack("a" .. C01 .. "b"),  '"a\\u0001b"')
check("encode ctrl 0x1F",    Json.pack("a" .. C1F .. "b"),  '"a\\u001fb"')
check("encode DEL 0x7F",     Json.pack("a" .. C7F .. "b"),  '"a' .. C7F .. 'b"')  -- DEL 不转义
check("encode high 0x80",    Json.pack("a" .. C80 .. "b"),  '"a' .. C80 .. 'b"')  -- 高字节原样
check("encode high 0xFF",    Json.pack("a" .. CFF .. "b"),  '"a' .. CFF .. 'b"')
check("encode mixed",        Json.pack('a"b\\c\nd'),  '"a\\"b\\\\c\\nd"')
check("encode only quote",   Json.pack('"'),          '"\\""')
check("encode only bslash",  Json.pack('\\'),         '"\\\\"')

----------------------------------------------------------------------
-- decode 边界
----------------------------------------------------------------------
check("decode empty",        Json.unpack('""'),       '')
check("decode plain",        Json.unpack('"hello"'),  'hello')
check("decode quote",        Json.unpack('"a\\"b"'),  'a"b')
check("decode backslash",    Json.unpack('"a\\\\b"'), 'a\\b')
check("decode slash",         Json.unpack('"a\\/b"'), 'a/b')
check("decode newline",      Json.unpack('"a\\nb"'),  'a\nb')
check("decode tab",          Json.unpack('"a\\tb"'),  'a\tb')
check("decode cr",           Json.unpack('"a\\rb"'),  'a\rb')
check("decode backspace",    Json.unpack('"a\\bb"'),  'a\bb')
check("decode formfeed",     Json.unpack('"a\\fb"'),  'a\fb')
check("decode u BMP A",      Json.unpack('"\\u0041"'), 'A')
check("decode u BMP zhong",  Json.unpack('"\\u4e2d"'), '中')
check("decode u lowercase",  Json.unpack('"\\u0061"'), 'a')       -- 小写 hex
check("decode u null",       Json.unpack('"\\u0000"'), string.char(0x00))
check("decode surrogate",    Json.unpack('"\\uD834\\uDD1E"'), SURROGATE_UTF8)
check("decode mixed",        Json.unpack('"a\\nb\\"c\\\\d"'), 'a\nb"c\\d')
check("decode esc at end",   Json.unpack('"a\\\\"'),  'a\\')
check("decode esc at start", Json.unpack('"\\\\a"'),  '\\a')
check("decode single plain", Json.unpack('"x"'),      'x')
check("decode consecutive esc", Json.unpack('"\\n\\t\\r"'), '\n\t\r')
check("decode only esc",     Json.unpack('"\\n\\n"'), '\n\n')
-- 无效转义 \q：宽松处理，透传为 q（现有行为，与 dkjson 一致）
check("decode invalid esc q", Json.unpack('"a\\qb"'), 'aqb')
-- 孤立高代理（无低代理跟随）：转为 3 字节 UTF-8（现有行为，非严格校验）
check("decode lone surrogate", Json.unpack('"\\uD834"'), string.char(0xED, 0xA0, 0xB4))

----------------------------------------------------------------------
-- 未闭合字符串（错误路径）
----------------------------------------------------------------------
check_err("unterminated plain",     function() Json.unpack('"abc') end, "unterminated")
check_err("unterminated after esc", function() Json.unpack('"a\\') end, "unterminated")
check_err("unterminated after u",  function() Json.unpack('"a\\u00') end, "unterminated")

----------------------------------------------------------------------
-- 其他异常输入
----------------------------------------------------------------------
check_err("empty input",       function() Json.unpack('') end, "unexpected end")
check_err("trailing content",  function() Json.unpack('"abc" garbage') end, "trailing")

----------------------------------------------------------------------
-- 深度控制
----------------------------------------------------------------------
do
    local saved = Json.max_depth
    Json.set_max_depth(10)
    local ok, _ = pcall(function()
        local s = '"a"'
        for _ = 1, 5 do s = '[' .. s .. ']' end
        Json.unpack(s)
    end)
    check("depth within limit", ok, true)

    check_err("depth exceeded", function()
        local s = '"a"'
        for _ = 1, 20 do s = '[' .. s .. ']' end
        Json.unpack(s)
    end, "depth limit")
    Json.set_max_depth(saved)
end

----------------------------------------------------------------------
-- roundtrip（编→解 应还原）
----------------------------------------------------------------------
local roundtrip_cases = {
    "", "plain", 'a"b', 'a\\b', 'a/b', "a\nb", "a\rb", "a\tb",
    "a\bb", "a\fb", "a" .. C01 .. "b", "a" .. C1F .. "b", 'a"b\\c\nd',
    "a" .. C7F .. "b", "a" .. C80 .. "b", "a" .. CFF .. "b",
    "中文", "emoji-free text", "mix \" and \\ and / here",
}
for i, v in ipairs(roundtrip_cases) do
    check("roundtrip #" .. i, Json.unpack(Json.pack(v)), v)
end

----------------------------------------------------------------------
-- 结果汇总
----------------------------------------------------------------------
print("=== JSON boundary test ===")
print(string.format("PASS: %d  FAIL: %d", pass, fail))
if #failures > 0 then
    print("")
    for _, f in ipairs(failures) do
        print(f)
        print("")
    end
    os.exit(1)
end
print("ALL PASSED")
