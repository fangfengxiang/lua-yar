-- yar/packager/packager.lua
-- Packager 工厂与注册表：按名称获取序列化器

local Json = require("yar.packager.json")
local Msgpack = require("yar.packager.msgpack")

local type, string = type, string

---@class Packager
---@field JSON string JSON packager name
---@field MSGPACK string Msgpack packager name
local _M = {}

-- Packager 名称常量（对齐 yar-c 的 YAR_PACKAGER_*，协议头中为 8 字节固定大写）
_M.JSON    = "JSON"
_M.MSGPACK = "MSGPACK"

--- Packager registry
local registry = {
    [_M.JSON]    = Json,
    [_M.MSGPACK] = Msgpack,
}

--- Register a packager from a library module
-- Accepts libraries with pack/unpack or encode/decode methods (e.g. cjson, cmsgpack).
-- Auto-detects interface, constructs adapter, and registers to the registry.
--
-- 参数校验是编程错误（调用方写错代码），用 error(msg, 2) fail-fast（ADR #33 修正）。
-- Packager.register 是全局注册 API，调用方是应用层（非库内部函数），
-- 编程错误直接抛错，不应返回 nil, err 让调用方检查。
--
-- unpack 契约（ADR #34）：unpack 对畸形数据必须返回 nil, errmsg，
-- 不能 error() 抛错。Protocol.parse 直接调用 unpack（无 pcall），
-- 若第三方库抛 error() 会导致协议层崩溃。
-- 内置 Json/Msgpack 已遵循此契约；注册第三方库时请确认其 unpack 返回 nil, err。
-- name 白名单：只允许 JSON/MSGPACK（协议兼容性，PHP Yar 只认这两种）。
-- register_packager 语义是"替换内置实现"（如 cjson 替换纯 Lua Json），不是新增 packager 类型。
---@param name string Packager name (case-insensitive), must be JSON or MSGPACK
---@param lib table Library with pack/unpack or encode/decode methods
---@return table adapter (name/pack/unpack)
function _M.register(name, lib)
    if type(name) ~= "string" or #name == 0 then
        error("name must be a non-empty string", 2)
    end
    if type(lib) ~= "table" then
        error("lib must be a table", 2)
    end
    local pack   = lib.pack or lib.encode
    local unpack = lib.unpack or lib.decode
    if type(pack) ~= "function" or type(unpack) ~= "function" then
        error("lib must have pack/unpack or encode/decode methods", 2)
    end
    -- 协议兼容性白名单：Yar 协议头 packager_name 字段 8 字节，PHP Yar 只认 JSON/MSGPACK。
    -- 非白名单 name 属于编程错误，error(msg, 2) fail-fast（ADR #33）。
    local upper_name = string.upper(name)
    if upper_name ~= _M.JSON and upper_name ~= _M.MSGPACK then
        error("packager name must be JSON or MSGPACK, got: " .. upper_name, 2)
    end
    local adapter = {
        name   = upper_name,
        pack   = pack,
        unpack = unpack,
    }
    registry[adapter.name] = adapter
    return adapter
end

--- Get packager by name
---@param name string Packager name (default JSON)
---@return table|nil packager module
---@return nil|string err error message
function _M.get(name)
    name = (name and string.upper(name)) or _M.JSON
    local p = registry[name]
    if not p then
        return nil, "unsupported packager: " .. name
    end
    return p
end

return _M
