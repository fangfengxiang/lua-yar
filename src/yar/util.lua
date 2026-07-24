-- yar/util.lua
-- Yar 通用工具：二进制字节序编解码、字符串填充
-- 所有二进制操作使用纯数学实现，兼容 Lua 5.1 / LuaJIT / 5.3+（LuaJIT 无 string.pack）

local string, math = string, math

---@class Util
local _M = {}

--- Pack big-endian uint16
---@param n number
---@return string 2 bytes big-endian
function _M.pack_u16(n)
    return string.char(
        math.floor(n / 0x100) % 0x100,
        n % 0x100)
end

--- Pack big-endian uint32
---@param n number
---@return string 4 bytes big-endian
function _M.pack_u32(n)
    return string.char(
        math.floor(n / 0x1000000) % 0x100,
        math.floor(n / 0x10000) % 0x100,
        math.floor(n / 0x100) % 0x100,
        n % 0x100)
end

--- Unpack big-endian uint16
---@param s string
---@param offset number Start position (1-based)
---@return number
function _M.unpack_u16(s, offset)
    local a, b = string.byte(s, offset, offset + 1)
    return a * 0x100 + b
end

--- Unpack big-endian uint32
---@param s string
---@param offset number Start position (1-based)
---@return number
function _M.unpack_u32(s, offset)
    local a, b, c, d = string.byte(s, offset, offset + 3)
    return a * 0x1000000 + b * 0x10000 + c * 0x100 + d
end

--- Right-pad string with \0 to target length, truncate if longer
---@param s string Original string
---@param size number Target length
---@return string
function _M.pad_field(s, size)
    s = s or ""
    local len = #s
    if len >= size then
        return s:sub(1, size)
    end
    return s .. string.rep("\0", size - len)
end

--- Trim trailing \0 from string
---@param s string
---@return string
function _M.trim_null(s)
    local n = #s
    while n > 0 and string.byte(s, n) == 0 do
        n = n - 1
    end
    return string.sub(s, 1, n)
end

return _M
