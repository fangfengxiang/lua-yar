-- test/benchmark_xlib.lua
-- 跨库性能对比：lua-yar vs dkjson vs cjson vs cmsgpack
-- 运行：luajit test/benchmark_xlib.lua

package.path = package.path .. ";./src/?.lua;./src/?/init.lua;./test/?.lua"
package.path = package.path .. ";/Users/frank/.luarocks/share/lua/5.1/?.lua"
package.cpath = package.cpath .. ";/Users/frank/.luarocks/lib/lua/5.1/?.so"

local Json    = require("yar.packager.json")
local Msgpack = require("yar.packager.msgpack")

local has_dkjson, dkjson = pcall(require, "dkjson")
local has_cjson, cjson = pcall(require, "cjson")
local has_cmsgpack, cmsgpack = pcall(require, "cmsgpack")

local function bench(name, fn, n)
    for _ = 1, math.min(n, 1000) do fn() end
    local start = os.clock()
    for _ = 1, n do fn() end
    local elapsed = os.clock() - start
    local ops = n / elapsed
    print(string.format("  %-42s %8d ops in %6.3fs  ->  %10.0f ops/s", name, n, elapsed, ops))
    return ops
end

-- 测试样本（与 benchmark_matrix.lua 一致）
local sample = { a = 1, b = "hello world", c = { 1, 2, 3, 4, 5 }, d = true, e = 3.14 }
local json_str = Json.pack(sample)
local msgpack_str = Msgpack.pack(sample)

print("=== Cross-Library Benchmark (LuaJIT) ===")
print(string.format("dkjson:   %s", has_dkjson and "loaded" or "NOT INSTALLED"))
print(string.format("cjson:    %s", has_cjson and cjson._VERSION or "NOT INSTALLED"))
print(string.format("cmsgpack: %s", has_cmsgpack and "loaded" or "NOT INSTALLED"))
print("")

----------------------------------------------------------------------
-- JSON encode
----------------------------------------------------------------------
print("[JSON encode]")
local yar_jpack = bench("  lua-yar Json.pack (pure-Lua)",  function() Json.pack(sample) end, 100000)
local dk_jpack  = has_dkjson and bench("  dkjson.encode",             function() dkjson.encode(sample) end, 100000) or 0
local cj_jpack  = has_cjson and bench("  cjson.encode",               function() cjson.encode(sample) end, 100000) or 0

if has_dkjson then
    print(string.format("  -> lua-yar vs dkjson:  %.2fx", yar_jpack / dk_jpack))
end
if has_cjson then
    print(string.format("  -> cjson vs lua-yar:   %.2fx", cj_jpack / yar_jpack))
    print(string.format("  -> cjson vs dkjson:   %.2fx", cj_jpack / dk_jpack))
end
print("")

----------------------------------------------------------------------
-- JSON decode
----------------------------------------------------------------------
print("[JSON decode]")
local yar_junpack = bench("  lua-yar Json.unpack (pure-Lua)", function() Json.unpack(json_str) end, 100000)
local dk_junpack  = has_dkjson and bench("  dkjson.decode",               function() dkjson.decode(json_str) end, 100000) or 0
local cj_junpack  = has_cjson and bench("  cjson.decode",                function() cjson.decode(json_str) end, 100000) or 0

if has_dkjson then
    print(string.format("  -> lua-yar vs dkjson:  %.2fx", yar_junpack / dk_junpack))
end
if has_cjson then
    print(string.format("  -> cjson vs lua-yar:   %.2fx", cj_junpack / yar_junpack))
    print(string.format("  -> cjson vs dkjson:    %.2fx", cj_junpack / dk_junpack))
end
print("")

----------------------------------------------------------------------
-- Msgpack encode
----------------------------------------------------------------------
print("[Msgpack encode]")
local yar_mpack = bench("  lua-yar Msgpack.pack (pure-Lua)",  function() Msgpack.pack(sample) end, 100000)
local cm_mpack  = has_cmsgpack and bench("  cmsgpack.pack",               function() cmsgpack.pack(sample) end, 100000) or 0

if has_cmsgpack then
    print(string.format("  -> cmsgpack vs lua-yar: %.2fx", cm_mpack / yar_mpack))
end
print("")

----------------------------------------------------------------------
-- Msgpack decode
----------------------------------------------------------------------
print("[Msgpack decode]")
local yar_munpack = bench("  lua-yar Msgpack.unpack (pure-Lua)", function() Msgpack.unpack(msgpack_str) end, 100000)
local cm_munpack  = has_cmsgpack and bench("  cmsgpack.unpack",               function() cmsgpack.unpack(msgpack_str) end, 100000) or 0

if has_cmsgpack then
    print(string.format("  -> cmsgpack vs lua-yar: %.2fx", cm_munpack / yar_munpack))
end
print("")

print("=== done ===")
