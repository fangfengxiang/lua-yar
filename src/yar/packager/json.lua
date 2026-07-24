-- yar/packager/json.lua
-- 纯 Lua JSON 编解码器（零依赖），用于 YAR 协议 body 的序列化与反序列化
-- 与 PHP Yar Server（配置 json packager）互通

local string, table, math, tonumber, type, pairs, tostring, next =
    string, table, math, tonumber, type, pairs, tostring, next

-- Unicode code point → UTF-8 byte string (JSON \uXXXX escape decoding)
local function unicode_to_utf8(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(
            0xC0 + math.floor(code / 0x40),
            0x80 + (code % 0x40))
    elseif code < 0x10000 then
        return string.char(
            0xE0 + math.floor(code / 0x1000),
            0x80 + (math.floor(code / 0x40) % 0x40),
            0x80 + (code % 0x40))
    else
        return string.char(
            0xF0 + math.floor(code / 0x40000),
            0x80 + (math.floor(code / 0x1000) % 0x40),
            0x80 + (math.floor(code / 0x40) % 0x40),
            0x80 + (code % 0x40))
    end
end

---@class Json
---@field name string Packager name (8 bytes, right-padded with \0)
---@field max_depth number Max nesting depth for decode (aligns with PHP json_decode default 512)
local _M = {}

--- Packager name, 8 bytes (right-padded with \0)
_M.name = "JSON"

--- Max nesting depth for decode (aligns with PHP json_decode default 512)
-- Exceeding the limit returns nil, nil, errmsg (对齐 dkjson.decode 惯例)。
_M.max_depth = 512

--- Set max nesting depth (aligns with lua-cjson set_max_depth API)
---@param n number Maximum nesting depth
function _M.set_max_depth(n) _M.max_depth = n end

----------------------------------------------------------------------
-- encode
----------------------------------------------------------------------

local function encode_string(s)
    -- 快路径：无需要转义的字符（控制字符 0x00-0x1F + " + \），直接拼接
    -- 借鉴 dkjson fsub 思路：先 find 检测，无匹配则跳过逐字节 buffer 分配
    if not s:find('[%c"\\]') then
        return '"' .. s .. '"'
    end
    -- 慢路径：逐字节转义
    local t = { '"' }
    for i = 1, #s do
        local b = string.byte(s, i)
        if b == 0x22 then        t[#t + 1] = '\\"'        -- "
        elseif b == 0x5C then    t[#t + 1] = '\\\\'       -- \
        elseif b == 0x0A then    t[#t + 1] = '\\n'
        elseif b == 0x0D then    t[#t + 1] = '\\r'
        elseif b == 0x09 then    t[#t + 1] = '\\t'
        elseif b == 0x08 then    t[#t + 1] = '\\b'
        elseif b == 0x0C then    t[#t + 1] = '\\f'
        elseif b < 0x20 then     t[#t + 1] = string.format('\\u%04x', b)
        else                     t[#t + 1] = string.char(b)
        end
    end
    t[#t + 1] = '"'
    return table.concat(t)
end

local encode

local function encode_number(n)
    if n ~= n or n == math.huge or n == -math.huge then
        return "null"
    end
    if math.floor(n) == n and n < 1e15 then
        return string.format("%.0f", n)
    end
    return string.format("%.14g", n)
end

local function encode_table(t, depth, max_depth)
    if depth > max_depth then
        error("json encode depth limit exceeded (" .. depth .. " > " .. max_depth .. ")", 0)
    end
    if next(t) == nil then
        return "[]"
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
        local parts = {}
        for i = 1, n do
            parts[i] = encode(t[i], depth + 1, max_depth)
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    -- 否则作为对象
    local parts = {}
    for k, v in pairs(t) do
        parts[#parts + 1] = encode_string(tostring(k)) .. ":" .. encode(v, depth + 1, max_depth)
    end
    return "{" .. table.concat(parts, ",") .. "}"
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
    if ty == "nil" then         return "null"
    elseif ty == "boolean" then return v and "true" or "false"
    elseif ty == "number" then  return encode_number(v)
    elseif ty == "string" then  return encode_string(v)
    elseif ty == "table" then   return encode_table(v, depth, max_depth)
    else                        return "null"
    end
end

--- Serialize a Lua value to a JSON string
---@param v any Value to serialize
---@return string JSON string
function _M.pack(v)
    return encode(v, 0, _M.max_depth or 512)
end

----------------------------------------------------------------------
-- decode（使用闭包保证可重入，OpenResty 多协程并发安全）
----------------------------------------------------------------------

-- 错误处理（upvalue 模式，ADR #37 修正延伸）：
-- 内部函数用 upvalue decode_err 报告错误，返回单值——消除多返回值 deopt
-- （LuaJIT 对变长返回值函数无法 JIT 编译，单返回值路径可全 JIT）。
-- 公开 API 仍返回 nil, pos, errmsg（对齐 dkjson.decode 惯例），由顶层转换。
-- 注意：JSON null 合法返回 nil（第一返回值），错误由 decode_err 非 nil 判定。
-- 规则：运行时错误 → 设 decode_err + return nil；error() 仅用于编程错误。

--- Deserialize a JSON string to a Lua value
---@param s string JSON string
---@return any|nil value Deserialized Lua value (nil on error or JSON null)
---@return number|nil pos Error position (1-based, nil on success)
---@return string|nil errmsg Error message (nil on success)
function _M.decode(s)
    local str, pos, len = s, 1, #s

    local max_depth = _M.max_depth or 512
    local depth = 0
    local decode_err  -- upvalue：内部函数设置错误消息，调用方检查

    local parse_value, parse_array, parse_object

    local function skip_ws()
        while pos <= len do
            local b = string.byte(str, pos)
            if b == 32 or b == 9 or b == 10 or b == 13 then
                pos = pos + 1
            else
                break
            end
        end
    end

    local function parse_string()
        -- dkjson 风格统一模式扫描：str:find('["\\]') 一次找 " 或 \，
        -- 找到后用 str:sub 取整段子串（C 层操作），替代逐字节 string.char + table 累积。
        -- 控制字符留在子串里（合法 JSON 不会裸出现，行为与逐字节 string.char 一致）。
        local start = pos + 1  -- 跳过起始 "
        local t, n = {}, 0
        local lastpos = start
        while true do
            local nextpos = str:find('["\\]', lastpos)
            if not nextpos then
                decode_err = "unterminated string"
                return nil
            end
            if nextpos > lastpos then
                n = n + 1
                t[n] = str:sub(lastpos, nextpos - 1)
            end
            local b = string.byte(str, nextpos)
            if b == 0x22 then  -- " 结束
                pos = nextpos + 1
                break
            end
            -- b == 0x5C 反斜杠转义
            pos = nextpos + 1  -- 指向转义字符
            if pos > len then
                decode_err = "unterminated string"
                return nil
            end
            local e = string.byte(str, pos)
            if e == 0x6E then      n = n + 1; t[n] = "\n"          -- n
            elseif e == 0x74 then  n = n + 1; t[n] = "\t"          -- t
            elseif e == 0x72 then  n = n + 1; t[n] = "\r"          -- r
            elseif e == 0x62 then  n = n + 1; t[n] = "\b"          -- b
            elseif e == 0x66 then  n = n + 1; t[n] = "\f"          -- f
            elseif e == 0x22 then  n = n + 1; t[n] = '"'
            elseif e == 0x5C then  n = n + 1; t[n] = "\\"
            elseif e == 0x2F then  n = n + 1; t[n] = "/"           -- /
            elseif e == 0x75 then  -- uXXXX
                local code = tonumber(string.sub(str, pos + 1, pos + 4), 16)
                pos = pos + 4
                if code then
                    -- UTF-16 代理对：高代理 0xD800-0xDBFF 后跟低代理 0xDC00-0xDFFF
                    -- 合并为 codepoint = 0x10000 + (hi-0xD800)*0x400 + (lo-0xDC00)
                    if code >= 0xD800 and code <= 0xDBFF then
                        if string.byte(str, pos + 1) == 0x5C and string.byte(str, pos + 2) == 0x75 then
                            local lo = tonumber(string.sub(str, pos + 3, pos + 6), 16)
                            if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                                pos = pos + 6
                                code = 0x10000 + (code - 0xD800) * 0x400 + (lo - 0xDC00)
                            end
                        end
                    end
                    n = n + 1; t[n] = unicode_to_utf8(code)
                end
            else
                n = n + 1; t[n] = string.char(e)
            end
            pos = pos + 1
            lastpos = pos
        end
        -- dkjson 优化：单段不 concat，避免单元素表的内存分配
        if n == 0 then return "" end
        if n == 1 then return t[1] end
        return table.concat(t)
    end

    -- 宽松数字解析：接受 JSON 标准数字及部分非标准格式（如前导 +）。
    -- 末尾 tonumber 校验保证不会返回无效数字，非标准输入会返回 nil。
    local function parse_number()
        local start = pos
        while pos <= len do
            local b = string.byte(str, pos)
            if (b >= 48 and b <= 57) or b == 45 or b == 43 or b == 46 or b == 101 or b == 69 then
                pos = pos + 1
            else
                break
            end
        end
        local num = tonumber(string.sub(str, start, pos - 1))
        if not num then
            decode_err = "invalid number at position " .. start
            return nil
        end
        return num
    end

    function parse_array()
        pos = pos + 1  -- 跳过 [
        local arr = {}
        local i = 1
        while true do
            skip_ws()
            if string.byte(str, pos) == 0x5D then  -- ]
                pos = pos + 1
                return arr
            end
            local v = parse_value()
            if decode_err then return nil end
            arr[i] = v
            i = i + 1
            skip_ws()
            local c = string.byte(str, pos)
            if c == 0x2C then        pos = pos + 1            -- ,
            elseif c == 0x5D then    pos = pos + 1; return arr
            else                     decode_err = "expected , or ] in array"; return nil
            end
        end
    end

    function parse_object()
        pos = pos + 1  -- 跳过 {
        local obj = {}
        while true do
            skip_ws()
            if string.byte(str, pos) == 0x7D then  -- }
                pos = pos + 1
                return obj
            end
            local key = parse_string()
            if decode_err then return nil end
            skip_ws()
            if string.byte(str, pos) ~= 0x3A then  -- :
                decode_err = "expected : in object"
                return nil
            end
            pos = pos + 1
            local v = parse_value()
            if decode_err then return nil end
            obj[key] = v
            skip_ws()
            local c = string.byte(str, pos)
            if c == 0x2C then        pos = pos + 1            -- ,
            elseif c == 0x7D then    pos = pos + 1; return obj
            else                     decode_err = "expected , or } in object"; return nil
            end
        end
    end

    -- 深度跟踪包装：进入 array/object 时递增，离开时递减
    -- 超限时设 decode_err 并返回 nil（对齐 dkjson.decode 惯例）
    local function descend(parser)
        depth = depth + 1
        if depth > max_depth then
            decode_err = "json depth limit exceeded (" .. depth .. " > " .. max_depth .. ")"
            return nil
        end
        local r = parser()
        depth = depth - 1
        return r
    end

    function parse_value()
        skip_ws()
        local b = string.byte(str, pos)
        if b == nil then            decode_err = "unexpected end of input"; return nil end
        if b == 0x22 then           return parse_string()            -- "
        elseif b == 0x7B then       return descend(parse_object)     -- {
        elseif b == 0x5B then       return descend(parse_array)      -- [
        elseif b == 0x74 then                                       -- true (t)
            if string.byte(str, pos + 1) ~= 0x72                 -- r
            or string.byte(str, pos + 2) ~= 0x75                 -- u
            or string.byte(str, pos + 3) ~= 0x65                 -- e
            then decode_err = "invalid literal at position " .. pos; return nil end
            pos = pos + 4; return true
        elseif b == 0x66 then                                       -- false (f)
            if string.byte(str, pos + 1) ~= 0x61                 -- a
            or string.byte(str, pos + 2) ~= 0x6C                 -- l
            or string.byte(str, pos + 3) ~= 0x73                 -- s
            or string.byte(str, pos + 4) ~= 0x65                 -- e
            then decode_err = "invalid literal at position " .. pos; return nil end
            pos = pos + 5; return false
        elseif b == 0x6E then                                       -- null (n)
            if string.byte(str, pos + 1) ~= 0x75                 -- u
            or string.byte(str, pos + 2) ~= 0x6C                 -- l
            or string.byte(str, pos + 3) ~= 0x6C                 -- l
            then decode_err = "invalid literal at position " .. pos; return nil end
            pos = pos + 4; return nil
        else                        return parse_number()
        end
    end

    local result = parse_value()
    if decode_err then
        return nil, pos, decode_err
    end
    skip_ws()
    if pos <= len then
        return nil, nil, "trailing content at position " .. pos
    end
    return result
end

--- Deserialize (alias, consistent with packager interface)
---@param s string JSON string
---@return any|nil value Deserialized Lua value (nil on error or JSON null)
---@return number|nil pos Error position (1-based, nil on success)
---@return string|nil errmsg Error message (nil on success)
function _M.unpack(s)
    return _M.decode(s)
end

return _M
