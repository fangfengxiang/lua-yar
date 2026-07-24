-- yar/packager/msgpack.lua
-- 纯 Lua MessagePack 编解码器（零依赖），用于 YAR 协议 body 的序列化与反序列化
-- 与 PHP Yar Server（配置 msgpack packager）及 yar-c 互通
-- 兼容 Lua 5.1 / LuaJIT / 5.3+（不使用 string.pack）

local Util = require("yar.util")

local string, math, type, table, pairs, next =
    string, math, type, table, pairs, next

---@class Msgpack
---@field name string Packager name (8 bytes, right-padded with \0)
local _M = {}

--- Packager name, 8 bytes (right-padded with \0)
_M.name = "MSGPACK"

--- Max nesting depth for decode (aligns with JSON packager and PHP msgpack_unpack)
-- Exceeding the limit returns nil, errmsg（对齐 lua-resty-redis 惯例）。
_M.max_depth = 512

--- Set max nesting depth (aligns with JSON packager API)
---@param n number Maximum nesting depth
function _M.set_max_depth(n) _M.max_depth = n end

----------------------------------------------------------------------
-- encode
----------------------------------------------------------------------

local encode

local function pack_u8(n)   -- 0xcc uint8
    return string.char(0xcc, n % 0x100)
end

local function pack_u16(n)  -- 0xcd uint16
    return string.char(0xcd) .. Util.pack_u16(n)
end

local function pack_u32(n)  -- 0xce uint32
    return string.char(0xce) .. Util.pack_u32(n)
end

local function pack_u64(n)  -- 0xcf uint64（Lua double 精确到 2^53）
    local hi = math.floor(n / 0x100000000)
    local lo = n % 0x100000000
    return string.char(0xcf) .. Util.pack_u32(hi) .. Util.pack_u32(lo)
end

local function pack_i8(n)   -- 0xd0 int8
    return string.char(0xd0, n % 0x100)
end

local function pack_i16(n)  -- 0xd1 int16（补码）
    if n < 0 then n = n + 0x10000 end
    return string.char(0xd1) .. Util.pack_u16(n)
end

local function pack_i32(n)  -- 0xd2 int32（补码）
    if n < 0 then n = n + 0x100000000 end
    return string.char(0xd2) .. Util.pack_u32(n)
end

local function pack_i64(n)  -- 0xd3 int64（补码）
    -- 分别计算 hi/lo 32 位，避免 n + 2^64 超出 double 精度（2^53）导致舍入。
    -- 所有中间量（n、n/2^32、n%2^32、hi+2^32）均在 double 精确整数范围内。
    local lo = n % 0x100000000
    local hi = math.floor(n / 0x100000000)
    if hi < 0 then hi = hi + 0x100000000 end  -- 负数补码：高位转无符号 32 位
    return string.char(0xd3) .. Util.pack_u32(hi) .. Util.pack_u32(lo)
end

--- Encode a double as IEEE754 big-endian 8 bytes (0xcb)
---@param n number Double value
---@return string 9 bytes (0xcb prefix + 8 bytes)
local function pack_double(n)
    if n == 0 then
        return string.char(0xcb, 0, 0, 0, 0, 0, 0, 0, 0)
    end
    local sign = 0
    if n < 0 or (n == 0 and 1 / n < 0) then  -- 负数或负零
        sign = 1
        n = -n
    end
    if n ~= n then  -- NaN
        return string.char(0xcb, 0x7f, 0xf8, 0, 0, 0, 0, 0, 0)
    end
    if n == math.huge then  -- Inf（sign 已提取）
        if sign == 1 then
            return string.char(0xcb, 0xff, 0xf0, 0, 0, 0, 0, 0, 0)  -- -Inf
        end
        return string.char(0xcb, 0x7f, 0xf0, 0, 0, 0, 0, 0, 0)      -- +Inf
    end
    local mant, exp = math.frexp(n)  -- 0.5 <= mant < 1, mant * 2^exp = n
    local biased = exp - 1 + 1023
    local frac = (mant * 2 - 1) * (2 ^ 52)  -- 52 位尾数整数
    local hi = sign * 0x80000000 + biased * 0x100000 + math.floor(frac / 0x100000000)
    local lo = frac % 0x100000000
    return string.char(0xcb) .. Util.pack_u32(hi) .. Util.pack_u32(lo)
end

local function encode_number(n)
    if n ~= n or n == math.huge or n == -math.huge then
        return pack_double(n)
    end
    if math.floor(n) == n then  -- 整数
        if n >= 0 then
            if n <= 0x7f then
                return string.char(n)                      -- positive fixint
            elseif n <= 0xff then
                return pack_u8(n)
            elseif n <= 0xffff then
                return pack_u16(n)
            elseif n <= 0xffffffff then
                return pack_u32(n)
            else
                return pack_u64(n)                         -- 2^32 ~ 2^53 精确
            end
        else
            if n >= -32 then
                return string.char(n % 0x100)              -- negative fixint (0xe0-0xff)
            elseif n >= -128 then
                return pack_i8(n)
            elseif n >= -32768 then
                return pack_i16(n)
            elseif n >= -2147483648 then
                return pack_i32(n)
            else
                return pack_i64(n)
            end
        end
    end
    return pack_double(n)
end

local function encode_string(s)
    local len = #s
    if len <= 31 then
        return string.char(0xa0 + len) .. s                -- fixstr
    elseif len <= 0xff then
        return string.char(0xd9, len) .. s                 -- str8
    elseif len <= 0xffff then
        return string.char(0xda) .. Util.pack_u16(len) .. s  -- str16
    else
        return string.char(0xdb) .. Util.pack_u32(len) .. s  -- str32
    end
end

local function encode_table(t, depth, max_depth)
    if depth > max_depth then
        error("msgpack encode depth limit exceeded (" .. depth .. " > " .. max_depth .. ")", 0)
    end
    if next(t) == nil then
        return string.char(0x90)                           -- fixarray(0)
    end
    -- 判断是否为序列数组：所有 key 为 1..n 连续正整数且无空洞
    local n, count = 0, 0
    local is_array = true
    for k in pairs(t) do
        count = count + 1
        if type(k) == "number" and k >= 1 and k == math.floor(k) then
            if k > n then n = k end
        else
            is_array = false
        end
    end
    if is_array and count == n then
        local header
        if n <= 15 then
            header = string.char(0x90 + n)                 -- fixarray
        elseif n <= 0xffff then
            header = string.char(0xdc) .. Util.pack_u16(n) -- array16
        else
            header = string.char(0xdd) .. Util.pack_u32(n) -- array32
        end
        local buf = { header }
        for i = 1, n do
            buf[i + 1] = encode(t[i], depth + 1, max_depth)
        end
        return table.concat(buf)
    end
    -- 否则作为 map
    local header
    if count <= 15 then
        header = string.char(0x80 + count)                 -- fixmap
    elseif count <= 0xffff then
        header = string.char(0xde) .. Util.pack_u16(count) -- map16
    else
        header = string.char(0xdf) .. Util.pack_u32(count) -- map32
    end
    local buf = { header }
    local i = 2
    for k, v in pairs(t) do
        buf[i] = encode(k, depth + 1, max_depth)
        buf[i + 1] = encode(v, depth + 1, max_depth)
        i = i + 2
    end
    return table.concat(buf)
end

-- encode/decode 错误处理不对称（Lua 生态惯例）：
-- decode 路径用 return nil, err（descend 函数 + max_depth 检查）。
-- encode 路径用 error()——与 cjson.encode/dkjson.encode 的鸭子类型一致，
-- 由调用方在边界处 pcall 捕获（ADR #37 修正：pcall 不在 render 内部）。
-- 详见 openspec/changes/encoder-cycle-protection/design.md 决策 4。
--
-- Note: Lua tables with nil values do not store those keys (Lua language semantics).
-- encode_table uses pairs(t) which skips nil-valued keys, so fields with nil
-- values are omitted from serialized output. PHP Yar clients treat missing
-- keys as null — behavior is compatible. See docs/protocol.md for details.
function encode(v, depth, max_depth)
    local ty = type(v)
    if ty == "nil" then         return string.char(0xc0)   -- nil
    elseif ty == "boolean" then return v and string.char(0xc3) or string.char(0xc2)
    elseif ty == "number" then  return encode_number(v)
    elseif ty == "string" then  return encode_string(v)
    elseif ty == "table" then   return encode_table(v, depth, max_depth)
    else                        return string.char(0xc0)
    end
end

--- Serialize a Lua value to a MessagePack byte string
---@param v any Value to serialize
---@return string MessagePack byte string
function _M.pack(v)
    return encode(v, 0, _M.max_depth or 512)
end

----------------------------------------------------------------------
-- decode（使用闭包保证可重入，OpenResty 多协程并发安全）
----------------------------------------------------------------------

-- 错误处理（upvalue 模式，ADR #37 修正延伸）：
-- 内部函数用 upvalue decode_err 报告错误，返回单值——消除多返回值 deopt
-- （LuaJIT 对变长返回值函数无法 JIT 编译，单返回值路径可全 JIT）。
-- 公开 API 仍返回 nil, errmsg（对齐 lua-resty-redis 惯例），由顶层转换。
-- 注意：MessagePack nil (0xc0) 合法返回 nil（第一返回值），错误由 decode_err 非 nil 判定。
-- 规则：运行时错误 → 设 decode_err + return nil；error() 仅用于编程错误。

--- Unpack an IEEE754 double from big-endian byte string
---@param s string Byte string
---@param offset number Start position (1-based)
---@return number Unpacked double value
local function unpack_double(s, offset)
    local hi = Util.unpack_u32(s, offset)
    local lo = Util.unpack_u32(s, offset + 4)
    local sign = (hi >= 0x80000000) and -1 or 1
    hi = hi % 0x80000000
    local exp = math.floor(hi / 0x100000)
    local frac = (hi % 0x100000) * 0x100000000 + lo
    if exp == 0 then
        if frac == 0 then
            return sign * 0.0
        end
        return sign * math.ldexp(frac / (2 ^ 52), 1 - 1023)  -- 非规格化
    elseif exp == 0x7ff then
        if frac == 0 then
            return sign * math.huge
        end
        return 0.0 / 0.0  -- NaN
    end
    return sign * math.ldexp((frac / (2 ^ 52)) + 1, exp - 1023)
end

--- Unpack an IEEE754 float32 from big-endian byte string
---@param s string Byte string
---@param offset number Start position (1-based)
---@return number Unpacked float value
local function unpack_float(s, offset)
    local bits = Util.unpack_u32(s, offset)
    local sign = (bits >= 0x80000000) and -1 or 1
    bits = bits % 0x80000000
    local exp = math.floor(bits / 0x800000)
    local frac = bits % 0x800000
    if exp == 0 then
        if frac == 0 then
            return sign * 0.0
        end
        return sign * math.ldexp(frac / 0x800000, 1 - 127)
    elseif exp == 0xff then
        if frac == 0 then
            return sign * math.huge
        end
        return 0.0 / 0.0
    end
    return sign * math.ldexp((frac / 0x800000) + 1, exp - 127)
end

--- Deserialize a MessagePack byte string to a Lua value
---@param s string MessagePack byte string
---@return any|nil value Deserialized Lua value (nil on error or MessagePack nil)
---@return string|nil errmsg Error message (nil on success)
function _M.unpack(s)
    local str, pos, len = s, 1, #s
    local max_depth = _M.max_depth or 512
    local depth = 0
    local decode_err  -- upvalue：内部函数设置错误消息，调用方检查

    local parse_value

    local function parse_string(b)
        local n
        if b >= 0xa0 and b <= 0xbf then  -- fixstr 0xa0-0xbf
            n = b - 0xa0
        elseif b == 0xd9 then         -- str8
            if pos > len then decode_err = "unexpected end of msgpack input"; return nil end
            n = string.byte(str, pos); pos = pos + 1
        elseif b == 0xda then         -- str16
            if pos + 1 > len then decode_err = "unexpected end of msgpack input"; return nil end
            n = Util.unpack_u16(str, pos); pos = pos + 2
        elseif b == 0xdb then         -- str32
            if pos + 3 > len then decode_err = "unexpected end of msgpack input"; return nil end
            n = Util.unpack_u32(str, pos); pos = pos + 4
        end
        -- n 不判 nil：parse_string 是闭包内部函数，仅由 parse_value 传入
        -- fixstr(0xa0-0xbf)/str8(0xd9)/str16(0xda)/str32(0xdb)，均有对应分支。
        -- 若调用方传入不匹配的 b，n 为 nil 会导致 pos + n - 1 报错——调用方自负其责。
        if pos + n - 1 > len then
            decode_err = "msgpack string length exceeds data"
            return nil
        end
        local r = string.sub(str, pos, pos + n - 1)
        pos = pos + n
        return r
    end

    local function parse_bin(n)
        if pos + n - 1 > len then
            decode_err = "msgpack bin length exceeds data"
            return nil
        end
        local r = string.sub(str, pos, pos + n - 1)
        pos = pos + n
        return r
    end

    local function parse_array(n)
        local arr = {}
        for i = 1, n do
            local v = parse_value()
            if decode_err then return nil end
            arr[i] = v
        end
        return arr
    end

    local function parse_map(n)
        local m = {}
        for _ = 1, n do
            local k = parse_value()
            if decode_err then return nil end
            local v = parse_value()
            if decode_err then return nil end
            m[k] = v
        end
        return m
    end

    -- 边界检查：确认 pos 后还有 n 字节可读，防止截断数据导致级联错误
    -- 失败时设 decode_err（void 函数，与其他内部函数 upvalue 模式一致）
    local function need(n)
        if pos + n - 1 > len then
            decode_err = "unexpected end of msgpack input"
        end
    end

    -- 深度跟踪包装：进入 array/map 时递增，离开时递减
    -- 超限时设 decode_err 并返回 nil（对齐 lua-resty-redis 惯例）
    local function descend(parser, n)
        depth = depth + 1
        if depth > max_depth then
            decode_err = "msgpack depth limit exceeded (" .. depth .. " > " .. max_depth .. ")"
            return nil
        end
        local r = parser(n)
        depth = depth - 1
        return r
    end

    function parse_value()
        if pos > len then
            decode_err = "unexpected end of msgpack input"
            return nil
        end
        local b = string.byte(str, pos)
        pos = pos + 1
        if b <= 0x7f then                       -- positive fixint
            return b
        elseif b <= 0x8f then                   -- fixmap
            return descend(parse_map, b - 0x80)
        elseif b <= 0x9f then                   -- fixarray
            return descend(parse_array, b - 0x90)
        elseif b <= 0xbf then                   -- fixstr
            return parse_string(b)
        elseif b >= 0xe0 then                   -- negative fixint
            return b - 0x100
        end
        -- 单字节类型标记
        if b == 0xc0 then      return nil                                   -- nil
        elseif b == 0xc2 then  return false                                 -- false
        elseif b == 0xc3 then  return true                                  -- true
        elseif b == 0xc4 then  -- bin8
            need(1); if decode_err then return nil end
            local n = string.byte(str, pos); pos = pos + 1; return parse_bin(n)
        elseif b == 0xc5 then  -- bin16
            need(2); if decode_err then return nil end
            local n = Util.unpack_u16(str, pos); pos = pos + 2; return parse_bin(n)
        elseif b == 0xc6 then  -- bin32
            need(4); if decode_err then return nil end
            local n = Util.unpack_u32(str, pos); pos = pos + 4; return parse_bin(n)
        elseif b == 0xca then  -- float32
            need(4); if decode_err then return nil end
            local r = unpack_float(str, pos); pos = pos + 4; return r
        elseif b == 0xcb then  -- float64
            need(8); if decode_err then return nil end
            local r = unpack_double(str, pos); pos = pos + 8; return r
        elseif b == 0xcc then  -- uint8
            need(1); if decode_err then return nil end
            local v = string.byte(str, pos); pos = pos + 1; return v
        elseif b == 0xcd then  -- uint16
            need(2); if decode_err then return nil end
            local v = Util.unpack_u16(str, pos); pos = pos + 2; return v
        elseif b == 0xce then  -- uint32
            need(4); if decode_err then return nil end
            local v = Util.unpack_u32(str, pos); pos = pos + 4; return v
        elseif b == 0xcf then  -- uint64
            need(8); if decode_err then return nil end
            local hi = Util.unpack_u32(str, pos)
            local lo = Util.unpack_u32(str, pos + 4)
            pos = pos + 8
            return hi * 0x100000000 + lo
        elseif b == 0xd0 then  -- int8
            need(1); if decode_err then return nil end
            local v = string.byte(str, pos); pos = pos + 1
            if v >= 0x80 then v = v - 0x100 end
            return v
        elseif b == 0xd1 then  -- int16
            need(2); if decode_err then return nil end
            local v = Util.unpack_u16(str, pos); pos = pos + 2
            if v >= 0x8000 then v = v - 0x10000 end
            return v
        elseif b == 0xd2 then  -- int32
            need(4); if decode_err then return nil end
            local v = Util.unpack_u32(str, pos); pos = pos + 4
            if v >= 0x80000000 then v = v - 0x100000000 end
            return v
        elseif b == 0xd3 then  -- int64
            need(8); if decode_err then return nil end
            local hi = Util.unpack_u32(str, pos)
            local lo = Util.unpack_u32(str, pos + 4)
            pos = pos + 8
            if hi >= 0x80000000 then
                -- 负数：先转有符号 hi 再合成，避免 hi*2^32+lo 超出 double 精度
                return (hi - 0x100000000) * 0x100000000 + lo
            end
            return hi * 0x100000000 + lo
        elseif b == 0xd9 or b == 0xda or b == 0xdb then  -- str8/16/32
            return parse_string(b)
        elseif b == 0xdc then  -- array16
            need(2); if decode_err then return nil end
            local n = Util.unpack_u16(str, pos); pos = pos + 2
            return descend(parse_array, n)
        elseif b == 0xdd then  -- array32
            need(4); if decode_err then return nil end
            local n = Util.unpack_u32(str, pos); pos = pos + 4
            return descend(parse_array, n)
        elseif b == 0xde then  -- map16
            need(2); if decode_err then return nil end
            local n = Util.unpack_u16(str, pos); pos = pos + 2
            return descend(parse_map, n)
        elseif b == 0xdf then  -- map32
            need(4); if decode_err then return nil end
            local n = Util.unpack_u32(str, pos); pos = pos + 4
            return descend(parse_map, n)
        end
        decode_err = "unsupported msgpack type byte: 0x" .. string.format("%02x", b)
        return nil
    end

    local result = parse_value()
    if decode_err then
        return nil, decode_err
    end
    return result
end

return _M
