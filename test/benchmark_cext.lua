-- test/benchmark_cext.lua
-- C 扩展注入压测：cjson / cmsgpack vs 纯 Lua 实现
-- 运行：lua test/benchmark_cext.lua
--
-- 对比维度：
--   1. 纯 Lua JSON  vs  lua-cjson (C 扩展)
--   2. 纯 Lua Msgpack  vs  lua-cmsgpack (C 扩展)
--   3. Protocol.render/parse 全链路：纯 Lua vs C 扩展注入

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local Yar      = require("yar")
local Json     = require("yar.packager.json")
local Msgpack  = require("yar.packager.msgpack")
local Protocol = require("yar.protocol.protocol")
local Request  = require("yar.message.request")

-- C 扩展探测（可选软依赖）
local has_cjson, cjson = pcall(require, "cjson")
local has_cmsgpack, cmsgpack = pcall(require, "cmsgpack")

local function bench(name, fn, n)
    for _ = 1, math.min(n, 1000) do fn() end
    local start = os.clock()
    for _ = 1, n do fn() end
    local elapsed = os.clock() - start
    local ops = n / elapsed
    print(string.format("  %-42s %8d ops in %6.3fs  ->  %10.0f ops/s",
        name, n, elapsed, ops))
    return ops
end

-- 测试样本
local sample = { a = 1, b = "hello world", c = { 1, 2, 3, 4, 5 }, d = true, e = 3.14 }
local json_str = Json.pack(sample)
local msgpack_str = Msgpack.pack(sample)

local req = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })

print("=== lua-yar C extension benchmark ===")
print("")
print(string.format("cjson:      %s", has_cjson and cjson._VERSION or "NOT INSTALLED"))
print(string.format("cmsgpack:   %s", has_cmsgpack and "0.4.0" or "NOT INSTALLED"))
print("")

----------------------------------------------------------------------
-- JSON: 纯 Lua vs cjson
----------------------------------------------------------------------
print("[JSON pack/unpack]")
local pure_json_pack = bench("  pure-Lua Json.pack",       function() Json.pack(sample) end, 100000)
local pure_json_unpack = bench("  pure-Lua Json.unpack",     function() Json.unpack(json_str) end, 100000)

if has_cjson then
    -- cjson API: encode/decode，注册为 JSON packager 替换纯 Lua 实现（协议层 name 仍是 JSON）
    local cjson_adapter = Yar.register_packager(Yar.PACKAGER_JSON, cjson)
    assert(cjson_adapter, "cjson adapter failed")

    local cjson_pack = bench("  cjson  Json.pack (encode)",  function() cjson.encode(sample) end, 100000)
    local cjson_unpack = bench("  cjson  Json.unpack (decode)", function() cjson.decode(json_str) end, 100000)

    print(string.format("  -> cjson pack  %.1fx faster than pure-Lua", cjson_pack / pure_json_pack))
    print(string.format("  -> cjson unpack %.1fx faster than pure-Lua", cjson_unpack / pure_json_unpack))
end
print("")

----------------------------------------------------------------------
-- Msgpack: 纯 Lua vs cmsgpack
----------------------------------------------------------------------
print("[Msgpack pack/unpack]")
local pure_mp_pack = bench("  pure-Lua Msgpack.pack",     function() Msgpack.pack(sample) end, 100000)
local pure_mp_unpack = bench("  pure-Lua Msgpack.unpack",   function() Msgpack.unpack(msgpack_str) end, 100000)

if has_cmsgpack then
    -- cmsgpack API: pack/unpack，注册为 MSGPACK packager
    local cmp_adapter = Yar.register_packager(Yar.PACKAGER_MSGPACK, cmsgpack)
    assert(cmp_adapter, "cmsgpack adapter failed")

    local cmp_pack = bench("  cmsgpack Msgpack.pack",     function() cmsgpack.pack(sample) end, 100000)
    local cmp_unpack = bench("  cmsgpack Msgpack.unpack",   function() cmsgpack.unpack(msgpack_str) end, 100000)

    print(string.format("  -> cmsgpack pack  %.1fx faster than pure-Lua", cmp_pack / pure_mp_pack))
    print(string.format("  -> cmsgpack unpack %.1fx faster than pure-Lua", cmp_unpack / pure_mp_unpack))
end
print("")

----------------------------------------------------------------------
-- Protocol 全链路：render + parse（含 header 打包/解包 + framing）
----------------------------------------------------------------------
print("[Protocol render/parse (full pipeline)]")
-- 用原始模块构造 packager，避免 cjson 注册后污染 registry
local jp = { name = "JSON", pack = Json.pack, unpack = Json.unpack }
local mp = { name = "MSGPACK", pack = Msgpack.pack, unpack = Msgpack.unpack }
local json_msg = Protocol.render(req, jp)
local msgpack_msg = Protocol.render(req, mp)

local pure_render_json = bench("  Protocol.render (pure-Lua JSON)",
    function() Protocol.render(req, jp) end, 50000)
local pure_parse_json  = bench("  Protocol.parse  (pure-Lua JSON)",
    function() Protocol.parse(json_msg, jp) end, 50000)
local pure_render_mp   = bench("  Protocol.render (pure-Lua Msgpack)",
    function() Protocol.render(req, mp) end, 50000)
local pure_parse_mp    = bench("  Protocol.parse  (pure-Lua Msgpack)",
    function() Protocol.parse(msgpack_msg, mp) end, 50000)

if has_cjson then
    -- 内联 adapter：协议名仍是 JSON，但不污染 registry
    local jp_c = { name = "JSON", pack = cjson.encode, unpack = cjson.decode }
    local cjson_msg = Protocol.render(req, jp_c)
    local c_render = bench("  Protocol.render (cjson JSON)",
        function() Protocol.render(req, jp_c) end, 50000)
    local c_parse  = bench("  Protocol.parse  (cjson JSON)",
        function() Protocol.parse(cjson_msg, jp_c) end, 50000)
    print(string.format("  -> cjson render %.1fx faster", c_render / pure_render_json))
    print(string.format("  -> cjson parse  %.1fx faster", c_parse / pure_parse_json))
end

if has_cmsgpack then
    local mp_c = { name = "MSGPACK", pack = cmsgpack.pack, unpack = cmsgpack.unpack }
    local cmp_msg = Protocol.render(req, mp_c)
    local c_render = bench("  Protocol.render (cmsgpack Msgpack)",
        function() Protocol.render(req, mp_c) end, 50000)
    local c_parse  = bench("  Protocol.parse  (cmsgpack Msgpack)",
        function() Protocol.parse(cmp_msg, mp_c) end, 50000)
    print(string.format("  -> cmsgpack render %.1fx faster", c_render / pure_render_mp))
    print(string.format("  -> cmsgpack parse  %.1fx faster", c_parse / pure_parse_mp))
end
print("")
print("=== done ===")
