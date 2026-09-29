-- test/benchmark/benchmark_core.lua
-- lua-yar 性能基准测试：JSON/Msgpack 编解码、协议渲染/解析
-- 运行：lua test/benchmark/benchmark_core.lua [--json]
--   --json: 输出 benchmark-action 兼容的 JSON 行（用于 CI 性能追踪）

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

-- --json 模式：输出 benchmark-action 兼容的 JSON 数组（单个 JSON 数组，含全部结果）
-- 用于 CI 性能基准追踪（benchmark-action/github-action-benchmark）
local json_mode = false
for _, a in ipairs(arg or {}) do
    if a == "--json" then json_mode = true end
end

local results = {}

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
    if not json_mode then
        print(string.format("  %-35s %8d ops in %6.3fs  ->  %10.0f ops/s",
            name, n, elapsed, ops))
    end
    table.insert(results, {
        name  = name:gsub("^%s+", ""),
        unit  = "ops/s",
        value = ops,
    })
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

if not json_mode then
    print("=== lua-yar benchmark ===")
    print("")
    print("[JSON]")
end
bench("  Json.pack",       function() Json.pack(sample) end, 100000)
bench("  Json.unpack",     function() Json.unpack(json_str) end, 100000)
if not json_mode then
    print("")
    print("[Msgpack]")
end
bench("  Msgpack.pack",    function() Msgpack.pack(sample) end, 100000)
bench("  Msgpack.unpack",  function() Msgpack.unpack(msgpack_str) end, 100000)
if not json_mode then
    print("")
    print("[Protocol]")
end
bench("  Protocol.render (JSON)",    function() Protocol.render(req, jp) end, 50000)
bench("  Protocol.parse (JSON)",      function() Protocol.parse(json_msg, jp) end, 50000)
bench("  Protocol.render (Msgpack)",  function() Protocol.render(req, mp) end, 50000)
bench("  Protocol.parse (Msgpack)",   function() Protocol.parse(msgpack_msg, mp) end, 50000)

if json_mode then
    -- 输出 benchmark-action 兼容的 JSON 数组：[ {"name","unit","value"}, ... ]
    -- customBiggerIsBetter 要求整个文件是单个 JSON 数组（非 JSON Lines）。
    -- 复用项目内置 Json.pack 保证字符串转义与 JSON 格式正确。
    print(Json.pack(results))
else
    print("")
    print("=== done ===")
end
