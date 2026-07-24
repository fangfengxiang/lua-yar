-- yar/init.lua
-- Yar Lua RPC 框架主入口。
-- 公共 API 表面：client、server、register_packager、get_packager、set_options、VERSION、PACKAGER_*。
-- server 为统一 Server Facade（支持 TCP/HTTP/宿主模式），不再分离 http_server/tcp_server。
-- 协议层、传输层、消息层、packager 内部模块为内部模块，不应被上层直接引用。

---@class Yar
---@field VERSION string Framework version
---@field PROTOCOL_VERSION integer Protocol version
---@field client Client Client class
---@field server Server Server Facade class (TCP/HTTP/host unified)
---@field error Error Error module
---@field log Log Log module
---@field PACKAGER_JSON string JSON packager name constant
---@field PACKAGER_MSGPACK string Msgpack packager name constant
local _M = {}

_M.VERSION          = "0.1.0"
_M.PROTOCOL_VERSION = 1

_M.client   = require("yar.client")
_M.server   = require("yar.server")
_M.error    = require("yar.error")
_M.log      = require("yar.log")

-- 打包器名称常量（对齐 yar-c 的 YAR_PACKAGER_JSON / YAR_PACKAGER_MSGPACK）
-- 协议头 8 字节 packager name 字段，PHP Yar 只认 JSON / MSGPACK
_M.PACKAGER_JSON    = "JSON"
_M.PACKAGER_MSGPACK = "MSGPACK"

-- HTTP 传输 Content-Type 常量（Yar 二进制协议 over HTTP 的标准 MIME 类型）
-- 直接引用 transport/constants.lua 叶子模块，无循环依赖风险
local TransportConst = require("yar.transport.constants")
_M.HTTP_TRANSPORT_CONTENT_TYPE = TransportConst.HTTP_CONTENT_TYPE_OCTET_STREAM

-- Packager 门面 API（收口内部模块，不导出 Yar.packager）
-- 设计原因：Yar 是统一适配入口，内部模块不应泄漏（对齐 lua-cjson / lua-resty-http 门面惯例）
local packager = require("yar.packager.packager")
local json     = require("yar.packager.json")
local msgpack  = require("yar.packager.msgpack")

--- Register a packager from a library module
-- Auto-detects pack/unpack or encode/decode interface (e.g. cjson, cmsgpack).
-- 注册 cjson/cmsgpack 时用 Yar.PACKAGER_JSON / Yar.PACKAGER_MSGPACK 常量替换内置实现，
-- 协议层 packager name 仍是 JSON / MSGPACK，保证 PHP Yar 互操作。
-- 参数校验是编程错误，error(msg, 2) fail-fast（透传自 packager.register）。
---@param name string Packager name (case-insensitive), use Yar.PACKAGER_JSON / Yar.PACKAGER_MSGPACK
---@param lib table Library with pack/unpack or encode/decode methods
---@return table adapter (name/pack/unpack)
function _M.register_packager(name, lib)
    return packager.register(name, lib)
end

--- Get packager by name
---@param name string Packager name (default JSON, case-insensitive)
---@return table|nil packager module
---@return nil|string err error message
function _M.get_packager(name)
    return packager.get(name)
end

--- Set global options (process-wide)
-- 支持的选项：
--   opts.packager.json_max_depth    -- 内置纯 Lua Json 解码最大递归深度
--   opts.packager.msgpack_max_depth -- 内置纯 Lua Msgpack 解码最大递归深度
-- 注：json_max_depth / msgpack_max_depth 只对内置纯 Lua packager 生效。
-- 注册 cjson 后用 cjson.set_max_depth() 自行配置。
---@param opts table Options table
function _M.set_options(opts)
    if not opts then return end
    local p = opts.packager
    if not p then return end
    if p.json_max_depth then json.set_max_depth(p.json_max_depth) end
    if p.msgpack_max_depth then msgpack.set_max_depth(p.msgpack_max_depth) end
end

-- 事务 ID 生成与种子管理（进程级全局状态）
-- 设计原则：库不越权播种 math.randomseed，种子管理交给应用层。
--   Yar.seed(fn)             注册并执行播种函数，建议在 OpenResty init_by_lua 阶段调用
--   Yar.set_id_generator(fn) 注入自定义 ID 生成器（绕过默认实现）
local request = require("yar.message.request")
_M.seed             = request.seed
_M.set_id_generator = request.set_id_generator

return _M
