-- test/benchmark.lua
-- lua-yar 性能基准测试：JSON/Msgpack 编解码、协议渲染/解析
-- 运行：lua test/benchmark.lua

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local Yar      = require("yar")
local Json     = require("yar.packager.json")
local Msgpack  = require("yar.packager.msgpack")
local Protocol = require("yar.protocol.protocol")
local Request  = require("yar.message.request")
local Packager = require("yar.packager.packager")

local function bench(name, fn, n)
    -- 预热（JIT 热路径编译）
    for _ = 1, math.min(n, 1000) do fn() end
    local start = os.clock()
    for _ = 1, n do fn() end
    local elapsed = os.clock() - start
    local ops = n / elapsed
    print(string.format("  %-35s %8d ops in %6.3fs  ->  %10.0f ops/s",
        name, n, elapsed, ops))
end

local jp = Packager.get(Packager.JSON)
local mp = Packager.get(Packager.MSGPACK)
assert(jp and mp, "packager init failed")

local sample = { a = 1, b = "hello world", c = { 1, 2, 3, 4, 5 }, d = true, e = 3.14 }
local json_str = Json.pack(sample)
local msgpack_str = Msgpack.pack(sample)

local req = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })
local json_msg = Protocol.render(req, jp)
local msgpack_msg = Protocol.render(req, mp)

print("=== lua-yar benchmark ===")
print("")
print("[JSON]")
bench("  Json.pack",       function() Json.pack(sample) end, 100000)
bench("  Json.unpack",     function() Json.unpack(json_str) end, 100000)
print("")
print("[Msgpack]")
bench("  Msgpack.pack",    function() Msgpack.pack(sample) end, 100000)
bench("  Msgpack.unpack",  function() Msgpack.unpack(msgpack_str) end, 100000)
print("")
print("[Protocol]")
bench("  Protocol.render (JSON)",    function() Protocol.render(req, jp) end, 50000)
bench("  Protocol.parse (JSON)",      function() Protocol.parse(json_msg, jp) end, 50000)
bench("  Protocol.render (Msgpack)",  function() Protocol.render(req, mp) end, 50000)
bench("  Protocol.parse (Msgpack)",   function() Protocol.parse(msgpack_msg, mp) end, 50000)
print("")
print("=== done ===")
