-- test/benchmark_matrix.lua
-- 跨运行时 × 跨打包器 × 跨传输器 矩阵压测
-- 运行：
--   lua5.1   test/benchmark_matrix.lua   (Lua 5.1)
--   lua5.3   test/benchmark_matrix.lua   (Lua 5.3)
--   luajit   test/benchmark_matrix.lua   (LuaJIT)
--   lua      test/benchmark_matrix.lua   (Lua 5.5)
--   resty    test/benchmark_matrix.lua    (OpenResty LuaJIT + cosocket)

local package_path = package.path
package.path = package_path .. ";./src/?.lua;./src/?/init.lua;./test/?.lua"

-- 运行时探测
local runtime = "unknown"
local jit_on = false
local has_ngx = false
if jit and jit.version then
    jit_on = true
    if ngx and ngx.socket then
        runtime = "OpenResty-LuaJIT"
        has_ngx = true
    else
        runtime = "LuaJIT-" .. jit.version
    end
elseif _VERSION == "Lua 5.1" then
    runtime = "Lua-5.1"
elseif _VERSION == "Lua 5.3" then
    runtime = "Lua-5.3"
elseif _VERSION == "Lua 5.4" then
    runtime = "Lua-5.4"
elseif _VERSION == "Lua 5.5" then
    runtime = "Lua-5.5"
end

-- C 扩展路径（各运行时独立编译）
local cpaths = {
    ["Lua-5.1"]      = "/Users/frank/.luarocks/lib/lua/5.1/?.so",
    ["Lua-5.3"]      = "/Users/frank/.luarocks53/lib/lua/5.3/?.so",
    ["LuaJIT"]       = "/Users/frank/.luarocks/lib/lua/5.1/?.so",
    ["OpenResty-LuaJIT"] = "/Users/frank/.luarocks-resty/lib/lua/5.1/?.so",
    ["Lua-5.5"]      = "/opt/homebrew/lib/lua/5.5/?.so",
}
-- 模糊匹配 cpath
if runtime:match("LuaJIT") and not runtime:match("OpenResty") then
    package.cpath = package.cpath .. ";" .. (cpaths["LuaJIT"] or "")
elseif runtime:match("OpenResty") then
    package.cpath = package.cpath .. ";" .. (cpaths["OpenResty-LuaJIT"] or "")
elseif runtime == "Lua-5.1" then
    package.cpath = package.cpath .. ";" .. (cpaths["Lua-5.1"] or "")
elseif runtime == "Lua-5.3" then
    package.cpath = package.cpath .. ";" .. (cpaths["Lua-5.3"] or "")
elseif runtime == "Lua-5.5" then
    package.cpath = package.cpath .. ";" .. (cpaths["Lua-5.5"] or "")
end

local Yar       = require("yar")
local Json      = require("yar.packager.json")
local Msgpack   = require("yar.packager.msgpack")
local Protocol  = require("yar.protocol.protocol")
local Framing   = require("yar.protocol.framing")
local Request   = require("yar.message.request")
local Server       = require("yar.server")
local TcpTransport = require("yar.server.tcp")

-- bench_server 端口：从环境变量读取（CI 可注入），默认 9600（test job 基址端口）
local BENCH_PORT = tonumber(os.getenv("BENCH_SERVER_PORT")) or 9600

-- C 扩展探测
local has_cjson, cjson = pcall(require, "cjson")
local has_cmsgpack, cmsgpack = pcall(require, "cmsgpack")

local function bench(name, fn, n)
    for _ = 1, math.min(n, 1000) do fn() end
    local start = os.clock()
    for _ = 1, n do fn() end
    local elapsed = os.clock() - start
    local ops = n / elapsed
    print(string.format("  %-50s %8d ops in %6.3fs  ->  %10.0f ops/s",
        name, n, elapsed, ops))
    return ops
end

-- mock cosocket（可重置）
local function resettable_mock(data)
    local pos = 1
    local sock = {
        receive = function(_, pattern)
            if type(pattern) == "number" then
                if pos > #data then return nil, "closed" end
                local chunk = string.sub(data, pos, pos + pattern - 1)
                pos = pos + #chunk
                return chunk
            end
            return nil
        end,
        send = function(_, d) return #d end,
        settimeout = function() end,
        settimeouts = function() end,
        close = function() end,
        setkeepalive = function() return true end,
    }
    return sock, function() pos = 1 end
end

-- 测试样本
local sample = { a = 1, b = "hello world", c = { 1, 2, 3, 4, 5 }, d = true, e = 3.14 }
local req = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })

-- 预渲染消息
local jp = Yar.get_packager(Yar.PACKAGER_JSON)
local mp = Yar.get_packager(Yar.PACKAGER_MSGPACK)
local json_msg = Protocol.render(req, jp)
local msgpack_msg = Protocol.render(req, mp)
local json_str = Json.pack(sample)
local msgpack_str = Msgpack.pack(sample)

-- C 扩展打包器（内联 adapter，不注册假名，协议层 name 仍是 JSON/MSGPACK）
local jp_c = has_cjson and { name = "JSON", pack = cjson.encode, unpack = cjson.decode } or nil
local mp_c = has_cmsgpack and { name = "MSGPACK", pack = cmsgpack.pack, unpack = cmsgpack.unpack } or nil
local cjson_msg = jp_c and Protocol.render(req, jp_c) or nil
local cmp_msg = mp_c and Protocol.render(req, mp_c) or nil

print(string.format("MATRIX\t%s\tcjson=%s\tcmsgpack=%s\tjit=%s",
    runtime, tostring(has_cjson), tostring(has_cmsgpack), tostring(jit_on)))
print("")

----------------------------------------------------------------------
-- 1. 序列化器裸编解码
----------------------------------------------------------------------
print("[Codec pack/unpack]")
local results = {}

results.json_pack_pure = bench("  Json.pack   (pure-Lua)",   function() Json.pack(sample) end, 100000)
results.json_unpack_pure = bench("  Json.unpack (pure-Lua)", function() Json.unpack(json_str) end, 100000)
results.mp_pack_pure = bench("  Msgpack.pack   (pure-Lua)",   function() Msgpack.pack(sample) end, 100000)
results.mp_unpack_pure = bench("  Msgpack.unpack (pure-Lua)", function() Msgpack.unpack(msgpack_str) end, 100000)

if has_cjson then
    results.json_pack_c = bench("  Json.pack   (cjson)",     function() cjson.encode(sample) end, 100000)
    results.json_unpack_c = bench("  Json.unpack (cjson)",   function() cjson.decode(json_str) end, 100000)
end
if has_cmsgpack then
    results.mp_pack_c = bench("  Msgpack.pack   (cmsgpack)",   function() cmsgpack.pack(sample) end, 100000)
    results.mp_unpack_c = bench("  Msgpack.unpack (cmsgpack)", function() cmsgpack.unpack(msgpack_str) end, 100000)
end
print("")

----------------------------------------------------------------------
-- 2. Protocol 全链路（render + parse）
----------------------------------------------------------------------
print("[Protocol render/parse]")
results.proto_render_json_pure = bench("  render JSON    (pure-Lua)",
    function() Protocol.render(req, jp) end, 50000)
results.proto_parse_json_pure = bench("  parse  JSON    (pure-Lua)",
    function() Protocol.parse(json_msg, jp) end, 50000)
results.proto_render_mp_pure = bench("  render Msgpack (pure-Lua)",
    function() Protocol.render(req, mp) end, 50000)
results.proto_parse_mp_pure = bench("  parse  Msgpack (pure-Lua)",
    function() Protocol.parse(msgpack_msg, mp) end, 50000)
if jp_c then
    results.proto_render_json_c = bench("  render JSON    (cjson)",
        function() Protocol.render(req, jp_c) end, 50000)
    results.proto_parse_json_c = bench("  parse  JSON    (cjson)",
        function() Protocol.parse(cjson_msg, jp_c) end, 50000)
end
if mp_c then
    results.proto_render_mp_c = bench("  render Msgpack (cmsgpack)",
        function() Protocol.render(req, mp_c) end, 50000)
    results.proto_parse_mp_c = bench("  parse  Msgpack (cmsgpack)",
        function() Protocol.parse(cmp_msg, mp_c) end, 50000)
end
print("")

----------------------------------------------------------------------
-- 3. Framing + I/O（mock cosocket）
----------------------------------------------------------------------
print("[Framing I/O (mock cosocket)]")
local sock_fr, reset_fr = resettable_mock(json_msg)
results.framing_recv = bench("  receive_message (JSON)",
    function() reset_fr(); Framing.receive_message(sock_fr) end, 100000)
print("")

----------------------------------------------------------------------
-- 4. Server.handle_connection 全链路（receive → parse → dispatch → render → send）
----------------------------------------------------------------------
print("[handle_connection (full pipeline)]")
local server = Server.new({ add = function(a, b) return a + b end })

local sock_hj, reset_hj = resettable_mock(json_msg)
results.hc_json_pure = bench("  handle_connection (pure-Lua JSON)",
    function() reset_hj(); TcpTransport.serve(sock_hj, server.dispatcher, { keepalive = false }) end, 50000)

local sock_hm, reset_hm = resettable_mock(msgpack_msg)
results.hc_mp_pure = bench("  handle_connection (pure-Lua Msgpack)",
    function() reset_hm(); TcpTransport.serve(sock_hm, server.dispatcher, { keepalive = false }) end, 50000)

if jp_c then
    local server_c = Server.new({ add = function(a, b) return a + b end })
    local sock_hcj, reset_hcj = resettable_mock(cjson_msg)
    results.hc_json_c = bench("  handle_connection (cjson)",
        function() reset_hcj(); TcpTransport.serve(sock_hcj, server_c.dispatcher, { keepalive = false }) end, 50000)
end
if mp_c then
    local server_m = Server.new({ add = function(a, b) return a + b end })
    local sock_hcm, reset_hcm = resettable_mock(cmp_msg)
    results.hc_mp_c = bench("  handle_connection (cmsgpack)",
        function() reset_hcm(); TcpTransport.serve(sock_hcm, server_m.dispatcher, { keepalive = false }) end, 50000)
end
print("")

----------------------------------------------------------------------
-- 5. OpenResty cosocket 真实 I/O — handle_connection 往返（仅 resty 环境）
----------------------------------------------------------------------
if has_ngx and ngx.socket and ngx.socket.tcp then
    print("[OpenResty cosocket real I/O — handle_connection round-trip]")

    -- 启动 bench_server 子进程（端口由 BENCH_PORT 决定）
    os.execute("lua test/bench_server.lua " .. BENCH_PORT .. " > /dev/null 2>&1 &")
    os.execute("sleep 1")

    local probe = ngx.socket.tcp()
    local ready = probe:connect("127.0.0.1", BENCH_PORT)
    if ready then probe:close() end

    if not ready then
        print("  [SKIP] bench_server not reachable on 127.0.0.1:" .. BENCH_PORT)
    else
        local sock_fn = ngx.socket.tcp

        -- 5a. 每次新建连接的完整往返（JSON）
        --     迭代数限制 2000：避免 TCP TIME_WAIT 端口耗尽
        results.rt_json_new = bench("  handle_connection round-trip (JSON, new conn)",
            function()
                local s = sock_fn()
                s:connect("127.0.0.1", BENCH_PORT)
                s:send(json_msg)
                Framing.receive_message(s)
                s:close()
            end, 2000)

        -- 5b. keepalive 单连接多次请求（JSON）
        local ka_sock = sock_fn()
        ka_sock:connect("127.0.0.1", BENCH_PORT)
        results.rt_json_ka = bench("  handle_connection round-trip (JSON, keepalive)",
            function()
                ka_sock:send(json_msg)
                Framing.receive_message(ka_sock)
            end, 10000)
        ka_sock:close()

        -- 5c. Msgpack 往返（keepalive，避免 TIME_WAIT）
        local ka_mp = sock_fn()
        ka_mp:connect("127.0.0.1", BENCH_PORT)
        results.rt_mp_ka = bench("  handle_connection round-trip (Msgpack, keepalive)",
            function()
                ka_mp:send(msgpack_msg)
                Framing.receive_message(ka_mp)
            end, 10000)
        ka_mp:close()

        -- 5d. C 扩展打包器往返（keepalive）
        if jp_c then
            local ka_cj = sock_fn()
            ka_cj:connect("127.0.0.1", BENCH_PORT)
            results.rt_cjson_ka = bench("  handle_connection round-trip (cjson, keepalive)",
                function()
                    ka_cj:send(cjson_msg)
                    Framing.receive_message(ka_cj)
                end, 10000)
            ka_cj:close()
        end
        if mp_c then
            local ka_cm = sock_fn()
            ka_cm:connect("127.0.0.1", BENCH_PORT)
            results.rt_cmp_ka = bench("  handle_connection round-trip (cmsgpack, keepalive)",
                function()
                    ka_cm:send(cmp_msg)
                    Framing.receive_message(ka_cm)
                end, 10000)
            ka_cm:close()
        end

        -- 对比汇总
        if results.hc_json_pure and results.rt_json_ka then
            print(string.format("  -> JSON:  real cosocket %.1fx slower than mock (I/O overhead)",
                results.hc_json_pure / results.rt_json_ka))
        end
        if results.hc_mp_pure and results.rt_mp_ka then
            print(string.format("  -> Msgpack: real cosocket %.1fx slower than mock (I/O overhead)",
                results.hc_mp_pure / results.rt_mp_ka))
        end
    end

    os.execute("pkill -f bench_server.lua 2>/dev/null")
    print("")
end

print("=== done ===")
