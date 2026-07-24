-- yar/protocol/header.lua
-- Yar 协议头：82 字节 packed 结构（网络字节序/大端）
-- 字段顺序：id(u32) version(u16) magic_num(u32) reserved(u32) provider([32]) token([32]) body_len(u32)

local Util = require("yar.util")

local string, setmetatable = string, setmetatable

---@class Header
---@field id number Transaction ID
---@field version number Protocol version
---@field magic_num number Magic number (0x80DFEC60)
---@field reserved number Reserved field
---@field provider string Request source
---@field token string Auth token
---@field body_len number Body length
local _M = {}
_M.__index = _M

---@type integer
_M.SIZE      = 82
---@type integer
_M.MAGIC_NUM = 0x80DFEC60
---@type integer
_M.VERSION   = 1

--- Construct a protocol header
---@param t table {id=, version=, provider=, token=, body_len=, reserved=}
---@return Header
function _M.new(t)
    local self = t or {}
    setmetatable(self, _M)
    self.id        = self.id or 0
    self.version   = self.version or _M.VERSION
    self.magic_num = self.magic_num or _M.MAGIC_NUM
    self.reserved  = self.reserved or 0
    self.provider  = self.provider or ""
    self.token     = self.token or ""
    self.body_len  = self.body_len or 0
    return self
end

--- Pack into 82-byte binary string (big-endian)
---@return string
function _M:pack()
    return Util.pack_u32(self.id)
        .. Util.pack_u16(self.version)
        .. Util.pack_u32(self.magic_num)
        .. Util.pack_u32(self.reserved)
        .. Util.pad_field(self.provider, 32)
        .. Util.pad_field(self.token, 32)
        .. Util.pack_u32(self.body_len)
end

--- Unpack protocol header from binary string
---@param data string At least offset + 81 bytes
---@param offset number Start position (default 1)
---@return Header|nil header on success
---@return string|nil err error message
function _M.unpack(data, offset)
    offset = offset or 1
    if #data < offset + _M.SIZE - 1 then
        return nil, "header data too short: need " .. (offset + _M.SIZE - 1)
            .. " bytes, got " .. #data
    end
    local magic = Util.unpack_u32(data, offset + 6)
    if magic ~= _M.MAGIC_NUM then
        return nil, "invalid magic number: " .. string.format("0x%08X", magic)
    end
    local self = setmetatable({}, _M)
    self.id        = Util.unpack_u32(data, offset)
    self.version   = Util.unpack_u16(data, offset + 4)
    self.magic_num = magic
    self.reserved  = Util.unpack_u32(data, offset + 10)
    self.provider  = Util.trim_null(string.sub(data, offset + 14, offset + 45))
    self.token     = Util.trim_null(string.sub(data, offset + 46, offset + 77))
    self.body_len  = Util.unpack_u32(data, offset + 78)
    return self
end

return _M
