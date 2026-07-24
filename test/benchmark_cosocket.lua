-- test/benchmark_cosocket.lua
-- OpenResty cosocket 传输层压测
--
-- 运行方式：
--   1. resty test/benchmark_cosocket.lua            -- OpenResty 环境下 cosocket I/O 压测
--   2. lua test/benchmark_cosocket.lua              -- 标准 Lua 下 mock cosocket 压测（框架开销基线）
--
-- 压测维度：
--   1. Framing.receive_exact  — 帧读取（mock cosocket / 真实 cosocket）
--   2. Framing.receive_message — 完整消息接收（packager 8B + header 82B + body）
--   3. Server.handle_connection — 全链路：receive → parse → dispatch → render → send
--   4. cosocket vs luasocket 对比（仅 resty 环境下可跑真实 cosocket）

local package_path = package.path
package.path = package_path .. ";./src/?.lua;./src/?/init.lua;./test/?.lua"

local Yar       = require("yar")
local Protocol  = require("yar.protocol.protocol")
local Framing   = require("yar.protocol.framing")
local Request   = require("yar.message.request")
local Server       = require("yar.server")
local TcpTransport = require("yar.server.tcp")
local Packager     = require("yar.packager.packager")

local is_resty = ngx ~= nil and ngx.socket ~= nil

-- bench_server 端口：从环境变量读取（CI 可注入），默认 9600（test job 基址端口）
local BENCH_PORT = tonumber(os.getenv("BENCH_SERVER_PORT")) or 9600

local function bench(name, fn, n)
    for _ = 1, math.min(n, 1000) do fn() end
    local start = os.clock()
    for _ = 1, n do fn() end
    local elapsed = os.clock() - start
    local ops = n / elapsed
    print(string.format("  %-45s %8d ops in %6.3fs  ->  %10.0f ops/s",
        name, n, elapsed, ops))
    return ops
end

-- mock cosocket：内存缓冲区模拟 cosocket receive/send 接口
-- 与 OpenResty cosocket 接口契约一致：receive(size) / send(data) / settimeouts() / setkeepalive()
-- (resettable_mock is the primary variant used in benchmarks below)

-- 可重置的 mock cosocket（用于循环压测，每次重置 pos）
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

local jp = Packager.get(Packager.JSON)
local mp = Packager.get(Packager.MSGPACK)

local req = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })
local json_msg = Protocol.render(req, jp)
local msgpack_msg = Protocol.render(req, mp)

print("=== lua-yar cosocket transport benchmark ===")
print("")
print(string.format("runtime:  %s", is_resty and "OpenResty (ngx.socket available)" or "standard Lua (mock cosocket)"))
print("")

----------------------------------------------------------------------
-- 1. Framing.receive_exact — 帧读取开销
----------------------------------------------------------------------
print("[Framing.receive_exact]")
local sock1, reset1 = resettable_mock(json_msg)
bench("  receive_exact (8B packager name)", function()
    reset1()
    Framing.receive_exact(sock1, 8)
end, 200000)

local sock2, reset2 = resettable_mock(json_msg)
bench("  receive_exact (82B header)", function()
    reset2()
    Framing.receive_exact(sock2, 82)
end, 200000)

local sock3, reset3 = resettable_mock(json_msg)
bench("  receive_exact (full message)", function()
    reset3()
    Framing.receive_exact(sock3, #json_msg)
end, 200000)
print("")

----------------------------------------------------------------------
-- 2. Framing.receive_message — 完整消息接收
----------------------------------------------------------------------
print("[Framing.receive_message]")
local sock4, reset4 = resettable_mock(json_msg)
bench("  receive_message (JSON)", function()
    reset4()
    Framing.receive_message(sock4)
end, 100000)

local sock5, reset5 = resettable_mock(msgpack_msg)
bench("  receive_message (Msgpack)", function()
    reset5()
    Framing.receive_message(sock5)
end, 100000)
print("")

----------------------------------------------------------------------
-- 3. Server.handle_connection — 全链路（receive → parse → dispatch → render → send）
----------------------------------------------------------------------
print("[Server.handle_connection (full pipeline)]")
local server = Server.new({
    add = function(a, b) return a + b end,
})

local sock6, reset6 = resettable_mock(json_msg)
local hc_json = bench("  handle_connection (JSON)", function()
    reset6()
    TcpTransport.serve(sock6, server.dispatcher, { keepalive = false })
end, 50000)

local sock7, reset7 = resettable_mock(msgpack_msg)
local hc_mp = bench("  handle_connection (Msgpack)", function()
    reset7()
    TcpTransport.serve(sock7, server.dispatcher, { keepalive = false })
end, 50000)
print("")

----------------------------------------------------------------------
-- 4. 纯协议开销 vs I/O 开销占比
----------------------------------------------------------------------
print("[Overhead breakdown]")
local proto_only = bench("  Protocol.parse only (no I/O)", function()
    Protocol.parse(json_msg, jp)
end, 50000)
local sock9, reset9 = resettable_mock(json_msg)
local full = bench("  receive_message + Protocol.parse", function()
    reset9()
    local data = Framing.receive_message(sock9)
    Protocol.parse(data, jp)
end, 50000)
-- ops/s 反比于耗时，I/O 占比 = (1 - full_ops/proto_ops) * 100
local io_pct = (1 - full / proto_only) * 100
print(string.format("  -> I/O framing overhead: %.1f%% of total (parse dominates %.1f%%)",
    io_pct, 100 - io_pct))
print("")

----------------------------------------------------------------------
-- 4b. C 扩展注入对全链路 handle_connection 的影响
----------------------------------------------------------------------
local has_cjson, cjson = pcall(require, "cjson")
local has_cmsgpack, cmsgpack = pcall(require, "cmsgpack")

if has_cjson or has_cmsgpack then
    print("[handle_connection with C extension injection]")
    if has_cjson then
        local jp_c = { name = "JSON", pack = cjson.encode, unpack = cjson.decode }
        local cjson_msg = Protocol.render(req, jp_c)
        local server_c = Server.new({ add = function(a, b) return a + b end })
        local sock_c, reset_c = resettable_mock(cjson_msg)
        local hc_cjson = bench("  handle_connection (cjson)", function()
            reset_c()
            TcpTransport.serve(sock_c, server_c.dispatcher, { keepalive = false })
        end, 50000)
        print(string.format("  -> cjson full pipeline %.1fx faster than pure-Lua JSON", hc_cjson / hc_json))
    end
    if has_cmsgpack then
        local mp_c = { name = "MSGPACK", pack = cmsgpack.pack, unpack = cmsgpack.unpack }
        local cmp_msg = Protocol.render(req, mp_c)
        local server_m = Server.new({ add = function(a, b) return a + b end })
        local sock_m, reset_m = resettable_mock(cmp_msg)
        local hc_cmp = bench("  handle_connection (cmsgpack)", function()
            reset_m()
            TcpTransport.serve(sock_m, server_m.dispatcher, { keepalive = false })
        end, 50000)
        print(string.format("  -> cmsgpack full pipeline %.1fx faster than pure-Lua Msgpack", hc_cmp / hc_mp))
    end
    print("")
end

----------------------------------------------------------------------
-- 5. OpenResty cosocket 真实 I/O 压测（仅 resty 环境）
--    启动 bench_server 子进程，cosocket 往返 handle_connection 全链路
----------------------------------------------------------------------
if is_resty then
    print("[OpenResty cosocket real I/O — handle_connection round-trip]")

    -- 启动 bench_server 子进程（luasocket TCP server，端口由 BENCH_PORT 决定）
    os.execute("lua test/bench_server.lua " .. BENCH_PORT .. " > /dev/null 2>&1 &")
    -- 等待服务端就绪（sleep 替代轮询，避免 cosocket 连接产生 TIME_WAIT 噪音）
    os.execute("sleep 1")

    -- 验证服务端可达（单次探测，不产生大量 TIME_WAIT）
    local probe = ngx.socket.tcp()
    local ready = probe:connect("127.0.0.1", BENCH_PORT)
    if ready then probe:close() end

    if not ready then
        print("  [SKIP] bench_server not reachable on 127.0.0.1:" .. BENCH_PORT)
    else
        local sock_fn = ngx.socket.tcp

        -- 5a. 每次新建连接的完整往返（connect → send → receive → close）
        --     服务端 handle_connection 走真实 cosocket I/O
        --     迭代数限制 2000：避免 TCP TIME_WAIT 端口耗尽
        local rt_new = bench("  handle_connection round-trip (new conn each)", function()
            local s = sock_fn()
            s:connect("127.0.0.1", BENCH_PORT)
            s:send(json_msg)
            Framing.receive_message(s)
            s:close()
        end, 2000)
        print(string.format("  -> vs mock cosocket: %.1fx slower (real I/O overhead)",
            hc_json / rt_new))

        -- 5b. keepalive 单连接多次请求（省去 connect/close 开销）
        local ka_sock = sock_fn()
        ka_sock:connect("127.0.0.1", BENCH_PORT)
        local rt_ka = bench("  handle_connection round-trip (keepalive conn)", function()
            ka_sock:send(json_msg)
            Framing.receive_message(ka_sock)
        end, 10000)
        ka_sock:close()
        print(string.format("  -> vs mock cosocket: %.1fx slower (real I/O overhead)",
            hc_json / rt_ka))
        print(string.format("  -> keepalive vs new-conn: %.1fx faster",
            rt_ka / rt_new))

        -- 5c. Msgpack 往返（keepalive，避免 TIME_WAIT）
        local ka_mp = sock_fn()
        ka_mp:connect("127.0.0.1", BENCH_PORT)
        local rt_mp = bench("  handle_connection round-trip (Msgpack, keepalive)", function()
            ka_mp:send(msgpack_msg)
            Framing.receive_message(ka_mp)
        end, 10000)
        ka_mp:close()
        print(string.format("  -> vs mock cosocket Msgpack: %.1fx slower",
            hc_mp / rt_mp))
    end

    -- 终止 bench_server 子进程
    os.execute("pkill -f bench_server.lua 2>/dev/null")
    print("")
end

print("=== done ===")
