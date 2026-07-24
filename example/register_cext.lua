-- example/register_cext.lua
-- C 扩展注入示例：用 cjson / cmsgpack 替换纯 Lua 序列化器
--
-- 标准 Lua 下纯 Lua JSON/Msgpack 序列化器是性能瓶颈。
-- 注入 C 扩展可获得 1.4-1.9x 加速（见 docs/api.md — C Extension Injection）。
-- 运行方式：lua example/register_cext.lua

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local Yar = require("yar")
local Protocol = require("yar.protocol.protocol")
local Request = require("yar.message.request")
local Response = require("yar.message.response")

-- ============================================================
-- 1. 探测 C 扩展是否可用（pcall 保护，缺失时优雅降级）
-- ============================================================

local has_cjson, cjson = pcall(require, "cjson")
local has_cmsgpack, cmsgpack = pcall(require, "cmsgpack")

if not has_cjson and not has_cmsgpack then
    print("cjson / cmsgpack 均未安装，退出。")
    print("安装方式：luarocks install lua-cjson  /  luarocks install lua-cmsgpack")
    os.exit(0)
end

-- ============================================================
-- 2. 注入 C 扩展（register 一次，后续所有请求生效）
-- ============================================================

if has_cjson then
    -- cjson 接口：encode / decode
    -- Yar.register_packager 自动检测 encode/decode，构造 adapter 并注册
    -- 用 Yar.PACKAGER_JSON 常量注册，协议层 packager name 仍是 JSON，保证 PHP Yar 互操作
    Yar.register_packager(Yar.PACKAGER_JSON, cjson)
    print("[cjson] 已注入为 JSON packager")
end

if has_cmsgpack then
    -- cmsgpack 接口：pack / unpack
    Yar.register_packager(Yar.PACKAGER_MSGPACK, cmsgpack)
    print("[cmsgpack] 已注入为 MSGPACK packager")
end

-- ============================================================
-- 3. 验证往返（注入后的 packager 行为正确）
-- ============================================================

local json_p = Yar.get_packager(Yar.PACKAGER_JSON)
local req = Request.new({ method = "add", params = { 10, 20 }, provider = "ci", token = "ct" })
local msg = Protocol.render(req, json_p)
local payload, header = Protocol.parse(msg, json_p)
assert(payload.m == "add", "method mismatch")
assert(payload.p[1] == 10, "param mismatch")
print(string.format("[验证] JSON 往返 OK: method=%s params=%s,%s id=%d",
    payload.m, payload.p[1], payload.p[2], header.id))

local resp = Response.new({ id = req.id }):set_retval(30)
local rmsg = Protocol.render(resp, json_p)
local rpayload = Protocol.parse(rmsg, json_p)
assert(rpayload.r == 30, "retval mismatch")
print(string.format("[验证] JSON 响应往返 OK: retval=%s status=%s", tostring(rpayload.r), rpayload.s))

print()
print("=== 完成 ===")
print("注入后的 packager 对所有后续 Client / Server 请求自动生效，无需重复注册。")
print()
print("OpenResty 环境注册时机：")
print("  init_worker_by_lua 阶段注册一次，该 worker 所有后续请求生效。")
print("  （模块级 registry 是 per-worker VM 状态，init_by_lua 不传播到 worker）")
