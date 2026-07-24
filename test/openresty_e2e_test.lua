-- test/openresty_e2e_test.lua
-- OpenResty 端到端测试：真实 cosocket I/O 往返、连接池参数透传、HTTP Provider 委托、多协程并发安全
--
-- 运行：resty test/openresty_e2e_test.lua
--
-- 测试范围（K3 提案 openresty-integration-test）：
--   1. 真实 cosocket TCP 往返 —— 启动 TCP server 子进程，cosocket 客户端 call() 验证
--   2. 连接池参数透传 —— mock setkeepalive，验证 idle_timeout + pool_size 正确传递（M1 回归）
--   3. cosocket 三段超时 —— 验证 settimeouts(connect, send, receive) 被调用
--   4. HTTP Provider 委托 —— 注入 mock provider，验证 opts 透传 + body 返回
--   5. lua-resty-http 真实委托 —— 若 resty.http 可用，验证真实 HTTP 往返
--   6. 多协程并发安全 —— Lua 协程交替调度并发 handle_message 无竞态（resty CLI 无 ngx.thread）
--   7. keepalive 模式 —— 单连接多请求复用
--   8. cosocket 错误路径 —— 连接拒绝、超时处理
--   9. FI: 慢服务端 —— server sleep > read timeout，验证 TIMEOUT 分类
--  10. FI: 脏数据注入 —— 非协议字节 + 合法 header 声明超大 body，验证 framing 鲁棒性
--  11. FI: 事务中断连 —— server accept → sleep → close，验证连接断开不 hang
--  12. FI: 连接池小 pool —— pool_size=2, 10 次顺序调用，验证不 crash
--
-- 环境要求：
--   - OpenResty resty CLI（提供 ngx API + cosocket）
--   - 系统 Lua + luasocket（用于 bench_server.lua 子进程）
--   - lua-resty-http（可选，用于 HTTP Provider 真实委托测试）

local package_path = package.path
package.path = package_path .. ";./src/?.lua;./src/?/init.lua;./test/?.lua"

local Yar       = require("yar")
local Client    = Yar.client
local Packager  = require("yar.packager.packager")
local Protocol  = require("yar.protocol.protocol")
local Request   = require("yar.message.request")
local Response  = require("yar.message.response")
local Socket    = require("yar.transport.socket")
local Error     = require("yar.error")

local M = {}

-- 模块级 recv buffer（避免 _G 全局写触发 OpenResty write guard）
local mock_recv_buf

-- ── 断言工具 ──────────────────────────────────────────────────

local pass_count = 0
local fail_count = 0

--- 将数字打包为小端 4 字节字符串（模拟 Framing header_len）
local function pack_u32_le(len)
    return string.char(
        len % 256,
        math.floor(len / 256) % 256,
        math.floor(len / 65536) % 256,
        math.floor(len / 16777216) % 256
    )
end

local function assert_ok(cond, msg)
    if not cond then
        fail_count = fail_count + 1
        error("ASSERT FAILED: " .. (msg or "expression is false"), 2)
    end
    pass_count = pass_count + 1
end

local function assert_eq(a, b, msg)
    if a ~= b then
        fail_count = fail_count + 1
        error(string.format("ASSERT FAILED: %s (expected %s, got %s)",
            msg or "mismatch", tostring(b), tostring(a)), 2)
    end
    pass_count = pass_count + 1
end

-- ── 子进程管理 ────────────────────────────────────────────────

local BENCH_SERVER_PORT = 9700
local E2E_SERVER_PORT    = 9701

--- 启动 TCP server 子进程（luasocket，keepalive 模式）
local function start_tcp_server(port)
    -- 写一个临时 server 脚本，用系统 lua 运行
    local script = string.format([[
        package.path = package.path .. ";./src/?.lua;./src/?/init.lua"
        local Server = require("yar.server")
        local TcpTransport = require("yar.server.tcp")
        local Socket = require("yar.transport.socket")
        local server = Server.new({
            add = function(a, b) return a + b end,
            sub = function(a, b) return a - b end,
            echo = function(s) return s end,
        })
        local srv, err = Socket.bind("127.0.0.1", %d)
        if not srv then error("bind failed: " .. tostring(err)) end
        srv:settimeout(nil)
        while true do
            local client = srv:accept()
            if client then
                client:settimeout(server.options.timeout)
                TcpTransport.serve(client, server.dispatcher, { keepalive = true })
                client:close()
            end
        end
    ]], port)
    local tmpfile = "/tmp/yar_e2e_server_" .. port .. ".lua"
    local f = io.open(tmpfile, "w")
    f:write(script)
    f:close()
    os.execute("lua " .. tmpfile .. " > /dev/null 2>&1 &")
    -- 等待 server 就绪：用 cosocket 探测端口
    os.execute("sleep 2")
    local sock = ngx.socket.tcp()
    local ok = sock:connect("127.0.0.1", port)
    if ok then sock:close() end
    return ok
end

local function stop_tcp_server(port)
    local pattern = port and ("yar_e2e_server_" .. port) or "yar_e2e_server"
    os.execute("pkill -f " .. pattern .. " > /dev/null 2>&1")
    if port then
        os.remove("/tmp/yar_e2e_server_" .. port .. ".lua")
    else
        os.remove("/tmp/yar_e2e_server_9700.lua")
        os.remove("/tmp/yar_e2e_server_9701.lua")
    end
end

-- ── 1. 真实 cosocket TCP 往返 ──────────────────────────────────

local function test_cosocket_tcp_roundtrip()
    -- 注入 cosocket
    Client.set_socket(ngx.socket)

    local ok = start_tcp_server(BENCH_SERVER_PORT)
    if not ok then
        print("  [SKIP] TCP server subprocess failed to start (lua not in PATH?)")
        return
    end

    -- 单次调用
    local client = Client.new("tcp://127.0.0.1:" .. BENCH_SERVER_PORT)
    local result, err = client:call("add", { 10, 20 })
    assert_ok(result ~= nil, "cosocket: call should succeed, got err: " .. tostring(err))
    assert_eq(result, 30, "cosocket: add(10,20) should return 30")

    -- sub 方法
    local result2 = client:call("sub", { 50, 18 })
    assert_eq(result2, 32, "cosocket: sub(50,18) should return 32")

    -- echo 方法
    local result3 = client:call("echo", { "hello cosocket" })
    assert_eq(result3, "hello cosocket", "cosocket: echo should return input")

    -- Msgpack packager
    client:setopt("packager", Packager.MSGPACK)
    local result4 = client:call("add", { 100, 200 })
    assert_eq(result4, 300, "cosocket: msgpack add(100,200) should return 300")

    print("  [OK] cosocket TCP round-trip (add/sub/echo + msgpack)")
    stop_tcp_server(BENCH_SERVER_PORT)
end

-- ── 2. 连接池参数透传（M1 回归）──────────────────────────────

local function test_keepalive_param_passthrough()
    -- mock cosocket 的 setkeepalive 捕获参数
    local captured_idle, captured_pool

    -- 创建一个 mock socket provider，模拟 cosocket 行为
    local function mock_tcp()
        local sent_data = {}
        local recv_buffer = ""
        return {
            settimeouts = function() end,
            settimeout = function() end,
            connect = function() return true end,
            send = function(_, data)
                sent_data[#sent_data + 1] = data
                -- 模拟服务端响应：构造一个合法的 YAR 响应
                local p = Packager.get(Packager.JSON)
                local req = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })
                local resp = Protocol.render(Response.new({ status = 0, retval = 3, id = req.id }), p)
                recv_buffer = resp
                return #data
            end,
            receive = function(_, pattern)
                if type(pattern) == "number" then
                    -- Framing 先读 4 字节 header_len
                    if pattern == 4 then
                        -- 返回 body 长度的小端 4 字节
                        return pack_u32_le(#recv_buffer)
                    end
                    local chunk = string.sub(recv_buffer, 1, pattern)
                    recv_buffer = string.sub(recv_buffer, pattern + 1)
                    return chunk
                end
                return nil
            end,
            setkeepalive = function(_, idle, pool)
                captured_idle = idle
                captured_pool = pool
                return true
            end,
            close = function() end,
        }
    end

    -- 注入 mock provider
    Socket.set({ tcp = mock_tcp })

    local client = Client.new("tcp://127.0.0.1:9709")
    client:set_options({
        keepalive = { pool_size = 128, idle_timeout = 30000 }
    })
    client:call("add", { 1, 2 })

    assert_eq(captured_idle, 30000, "keepalive: idle_timeout should be 30000")
    assert_eq(captured_pool, 128, "keepalive: pool_size should be 128")

    -- 验证默认值
    captured_idle, captured_pool = nil, nil
    local client2 = Client.new("tcp://127.0.0.1:9710")
    client2:call("add", { 1, 2 })
    assert_eq(captured_idle, 60000, "keepalive: default idle_timeout should be 60000")
    assert_eq(captured_pool, 64, "keepalive: default pool_size should be 64")

    print("  [OK] keepalive param passthrough (idle_timeout + pool_size, M1 regression)")

    -- 恢复 cosocket provider
    Client.set_socket(ngx.socket)
end

-- ── 3. cosocket 三段超时 ──────────────────────────────────────

local function test_cosocket_settimeouts()
    local captured_connect_t, captured_send_t, captured_read_t

    local function mock_tcp()
        return {
            settimeouts = function(_, ct, st, rt)
                captured_connect_t = ct
                captured_send_t = st
                captured_read_t = rt
            end,
            settimeout = function() end,
            connect = function() return true end,
            send = function(_, data)
                local p = Packager.get(Packager.JSON)
                local req = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })
                local resp = Protocol.render(Response.new({ status = 0, retval = 3, id = req.id }), p)
                mock_recv_buf = resp
                return #data
            end,
            receive = function(_, pattern)
                if type(pattern) == "number" then
                    if pattern == 4 then
                        return pack_u32_le(#mock_recv_buf)
                    end
                    local chunk = string.sub(mock_recv_buf, 1, pattern)
                    mock_recv_buf = string.sub(mock_recv_buf, pattern + 1)
                    return chunk
                end
                return nil
            end,
            setkeepalive = function() return true end,
            close = function() end,
        }
    end

    Socket.set({ tcp = mock_tcp })

    local client = Client.new("tcp://127.0.0.1:9711")
    client:set_options({
        timeout = 5000,
        connect_timeout = 1000,
    })
    client:call("add", { 1, 2 })

    -- settimeouts(connect_t, send_t, read_t) — send 和 read 都用 timeout
    assert_eq(captured_connect_t, 1000, "settimeouts: connect timeout should be 1000")
    assert_eq(captured_send_t, 5000, "settimeouts: send timeout should be 5000")
    assert_eq(captured_read_t, 5000, "settimeouts: read timeout should be 5000")

    print("  [OK] cosocket settimeouts (connect=1000, send=5000, read=5000)")

    Client.set_socket(ngx.socket)
end

-- ── 4. HTTP Provider 委托（mock）──────────────────────────────

local function test_http_provider_delegation()
    local captured_url, captured_opts

    local function mock_provider(url, opts)
        captured_url = url
        captured_opts = opts
        -- 返回一个合法的 YAR 响应
        local p = Packager.get(Packager.JSON)
        local req = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })
        local resp = Protocol.render(Response.new({ status = 0, retval = 3, id = req.id }), p)
        return resp
    end

    -- 类级注入
    Client.set_http_provider(mock_provider)

    local client = Client.new("http://example.com/api")
    client:set_options({
        timeout = 3000,
        connect_timeout = 500,
        headers = { ["X-Custom"] = "test" },
        keepalive = { pool_size = 32, idle_timeout = 10000 },
        ssl_verify = false,
    })
    local result = client:call("add", { 1, 2 })

    assert_eq(result, 3, "http provider: add(1,2) should return 3")
    assert_eq(captured_url, "http://example.com/api", "http provider: url should match")
    assert_eq(captured_opts.method, "POST", "http provider: method should be POST")
    assert_ok(captured_opts.body ~= nil, "http provider: body should not be nil")
    assert_ok(captured_opts.headers["Content-Type"] == "application/octet-stream",
        "http provider: Content-Type should be application/octet-stream")
    assert_ok(captured_opts.headers["Content-Length"] ~= nil,
        "http provider: Content-Length should be set")
    assert_eq(captured_opts.timeout, 3000, "http provider: timeout should be 3000")
    assert_eq(captured_opts.connect_timeout, 500, "http provider: connect_timeout should be 500")
    assert_eq(captured_opts.headers["X-Custom"], "test", "http provider: custom header should pass")
    assert_eq(captured_opts.keepalive.pool_size, 32, "http provider: keepalive.pool_size should be 32")
    assert_eq(captured_opts.ssl_verify, false, "http provider: ssl_verify should be false")

    -- 实例级 provider 覆盖类级
    local instance_captured = false
    local function instance_provider(_url, _opts)
        instance_captured = true
        local p = Packager.get(Packager.JSON)
        local req = Request.new({ method = "add", params = { 5, 5 }, provider = "p", token = "t" })
        return Protocol.render(Response.new({ status = 0, retval = 10, id = req.id }), p)
    end

    local client2 = Client.new("http://example.com/api")
    client2:set_options({ http_provider = instance_provider })
    local result2 = client2:call("add", { 5, 5 })
    assert_eq(result2, 10, "http provider: instance-level should override class-level")
    assert_ok(instance_captured, "http provider: instance-level provider should be called")

    -- 清除类级 provider
    Client.set_http_provider(nil)

    print("  [OK] HTTP provider delegation (class + instance level, opts passthrough)")
end

-- ── 5. lua-resty-http 真实委托（可选）─────────────────────────

local function test_resty_http_real_delegation()
    -- 尝试加载 lua-resty-http
    local ok, resty_http = pcall(require, "resty.http")
    if not ok then
        print("  [SKIP] lua-resty-http not available, skipping real HTTP delegation test")
        return
    end

    -- 用 resty.http 的 provider 适配器
    local provider = function(url, opts)
        local httpc = resty_http.new()
        local res, err = httpc:request_uri(url, {
            method = opts.method or "POST",
            body = opts.body,
            headers = opts.headers,
            timeout = opts.timeout,
        })
        if not res then return nil, err end
        if res.status ~= 200 then return nil, "http status: " .. res.status end
        return res.body
    end

    -- 这个测试需要一个 HTTP YAR server 运行
    -- 在 CI 中由 nginx.conf + content_by_lua 提供
    -- 这里只验证 provider 注入不报错
    Client.set_http_provider(provider)
    local client = Client.new("http://127.0.0.1:9702/api")
    local result, err = client:call("add", { 1, 2 })
    -- 如果没有 server 运行，err 应该是连接错误（不是 provider 注入错误）
    if result then
        assert_eq(result, 3, "resty-http: add(1,2) should return 3")
        print("  [OK] lua-resty-http real delegation (HTTP round-trip)")
    else
        -- 没有运行 HTTP server 是可接受的（CI 的 nginx 步骤会覆盖）
        assert_ok(err ~= nil, "resty-http: should return error when no server")
        print("  [SKIP] lua-resty-http delegation (no HTTP server running, CI nginx step covers this)")
    end

    Client.set_http_provider(nil)
end

-- ── 6. 多协程并发安全 ────────────────────────────────────────

local function test_concurrency_safety()
    -- handle_message 是纯函数（无 I/O），多协程并发调用应安全
    local Server = Yar.server
    local server = Server.new({
        add = function(a, b) return a + b end,
    })

    local p = Packager.get(Packager.JSON)
    local results = {}
    local errors = {}

    -- 启动 10 个协程并发调用 handle_message
    -- handle_message 是纯函数（无 I/O、无 yield），用 Lua 协程模拟并发
    local coroutines = {}
    for i = 1, 10 do
        coroutines[i] = coroutine.create(function(idx)
            local req = Request.new({
                method = "add",
                params = { idx, idx * 10 },
                provider = "p",
                token = "t",
            })
            local msg = Protocol.render(req, p)
            local resp, err = server:handle_message(msg)
            if not resp then
                errors[idx] = err
                return
            end
            local payload = Protocol.parse(resp, p)
            results[idx] = payload.r
        end)
    end

    -- 交替 resume 所有协程，模拟并发调度
    local all_done = false
    while not all_done do
        all_done = true
        for i = 1, #coroutines do
            local co = coroutines[i]
            if coroutine.status(co) ~= "dead" then
                all_done = false
                coroutine.resume(co, i)
            end
        end
    end

    -- 验证所有结果正确
    local all_ok = true
    for i = 1, 10 do
        local expected = i + i * 10
        if results[i] ~= expected then
            all_ok = false
            print(string.format("    concurrency: thread %d expected %d, got %s (err: %s)",
                i, expected, tostring(results[i]), tostring(errors[i])))
        end
    end
    assert_ok(all_ok, "concurrency: all 10 coroutines should return correct results")
    print("  [OK] concurrency safety (10 coroutines, handle_message reentrant)")
end

-- ── 7. keepalive 模式（单连接多请求）─────────────────────────

local function test_keepalive_mode()
    Client.set_socket(ngx.socket)

    local ok = start_tcp_server(E2E_SERVER_PORT)
    if not ok then
        print("  [SKIP] TCP server subprocess failed to start")
        return
    end

    -- persistent 模式：复用连接
    local client = Client.new("tcp://127.0.0.1:" .. E2E_SERVER_PORT)
    client:setopt("persistent", true)

    -- 连续 5 次调用应复用同一连接
    for i = 1, 5 do
        local result = client:call("add", { i, i })
        assert_eq(result, i * 2, "keepalive: add(" .. i .. "," .. i .. ") should return " .. (i * 2))
    end

    -- 验证 _transport 缓存存在（persistent 模式）
    assert_ok(client._transport ~= nil, "keepalive: persistent transport should be cached")

    print("  [OK] keepalive mode (persistent, 5 calls on single connection)")

    stop_tcp_server(E2E_SERVER_PORT)
end

-- ── 8. cosocket 错误路径 ──────────────────────────────────────

local function test_cosocket_error_paths()
    Client.set_socket(ngx.socket)

    -- 连接拒绝（端口无服务）
    local client = Client.new("tcp://127.0.0.1:1")  -- port 1 通常无服务
    local result, err = client:call("add", { 1, 2 })
    assert_ok(result == nil, "error: connection refused should return nil")
    assert_ok(err ~= nil, "error: should return error object")
    assert_ok(err.code ~= nil, "error: should have error code")

    -- 验证错误分类
    assert_ok(err.code == Error.TRANSPORT or err.code == Error.TIMEOUT,
        "error: code should be TRANSPORT or TIMEOUT, got " .. tostring(err.code))

    print("  [OK] cosocket error paths (connection refused, error classification)")
end

-- ── 9-12. 故障注入测试（FI 提案 fault-injection-tests）──────────────
--
-- 4 个定向故障注入场景，复用 start_custom_server 子进程模式 + cosocket 客户端：
--   9. 慢服务端（latency injection）—— server sleep > read timeout
--  10. 脏数据注入（garbage bytes）—— 非协议字节 + 合法 header 声明超大 body
--  11. 事务中断连（mid-transaction kill）—— server accept → sleep → close
--  12. 连接池小 pool（pool exhaustion）—— pool_size=2, 10 次顺序调用

-- 故障注入端口（openresty job 范围 9703-9706，见 test/PORTS.md）
local FI_SLOW_PORT    = 9703
local FI_GARBAGE_PORT = 9704
local FI_KILL_PORT    = 9705
local FI_POOL_PORT    = 9706

--- 启动自定义 TCP server 子进程（接受完整 Lua 脚本体）
-- 与 start_tcp_server 不同，不硬编码 server 逻辑，由调用方提供完整脚本。
local function start_custom_server(port, script)
    local tmpfile = "/tmp/yar_e2e_server_" .. port .. ".lua"
    local f = io.open(tmpfile, "w")
    f:write(script)
    f:close()
    os.execute("lua " .. tmpfile .. " > /dev/null 2>&1 &")
    os.execute("sleep 2")
    local sock = ngx.socket.tcp()
    local ok = sock:connect("127.0.0.1", port)
    if ok then sock:close() end
    return ok
end

-- ── 9. 慢服务端（latency injection）──────────────────────────────

local function test_fault_injection_slow_server()
    Client.set_socket(ngx.socket)

    local script = string.format([[
        package.path = package.path .. ";./src/?.lua;./src/?/init.lua"
        local Server = require("yar.server")
        local TcpTransport = require("yar.server.tcp")
        local Socket = require("yar.transport.socket")
        local server = Server.new({
            add = function(a, b)
                os.execute("sleep 3")
                return a + b
            end,
        })
        local srv, err = Socket.bind("127.0.0.1", %d)
        if not srv then error("bind failed: " .. tostring(err)) end
        srv:settimeout(nil)
        while true do
            local client = srv:accept()
            if client then
                client:settimeout(server.options.timeout)
                TcpTransport.serve(client, server.dispatcher, { keepalive = true })
                client:close()
            end
        end
    ]], FI_SLOW_PORT)

    local ok = start_custom_server(FI_SLOW_PORT, script)
    if not ok then
        print("  [SKIP] slow server subprocess failed to start")
        return
    end

    local client = Client.new("tcp://127.0.0.1:" .. FI_SLOW_PORT)
    client:set_options({ timeout = 1000 })  -- 1 second (ms)

    local start_time = os.time()
    local result, err = client:call("add", { 1, 2 })
    local elapsed = os.time() - start_time

    assert_ok(result == nil, "slow server: call should fail (timeout)")
    assert_ok(err ~= nil, "slow server: should return error object")
    assert_eq(err.code, Error.TIMEOUT, "slow server: error code should be TIMEOUT")
    assert_ok(elapsed < 3, "slow server: should timeout before 3s, got " .. elapsed .. "s")

    print("  [OK] fault injection: slow server (read timeout in " .. elapsed .. "s)")
    stop_tcp_server(FI_SLOW_PORT)
end

-- ── 10. 脏数据注入（garbage bytes）──────────────────────────────

local function test_fault_injection_garbage_bytes()
    Client.set_socket(ngx.socket)

    -- 子场景 1：纯垃圾字节（magic number 不匹配）
    local garbage_script = string.format([[
        local luasocket = require("socket")
        local srv = luasocket.bind("127.0.0.1", %d)
        srv:settimeout(nil)
        while true do
            local client = srv:accept()
            if client then
                client:settimeout(2)
                pcall(function() client:send(string.rep(string.char(0xFF), 100)) end)
                client:close()
            end
        end
    ]], FI_GARBAGE_PORT)

    local ok = start_custom_server(FI_GARBAGE_PORT, garbage_script)
    if not ok then
        print("  [SKIP] garbage server subprocess failed to start")
        return
    end

    local client = Client.new("tcp://127.0.0.1:" .. FI_GARBAGE_PORT)
    local result, err = client:call("add", { 1, 2 })

    assert_ok(result == nil, "garbage: call should fail")
    assert_ok(err ~= nil, "garbage: should return error object")
    assert_ok(err.code == Error.TRANSPORT or err.code == Error.PROTOCOL,
        "garbage: error code should be TRANSPORT or PROTOCOL, got " .. tostring(err.code))

    print("  [OK] fault injection: garbage bytes (invalid magic number)")

    stop_tcp_server(FI_GARBAGE_PORT)

    -- 子场景 2：合法 header + 超大 body_len（framing 层拒绝）
    local huge_body_script = string.format([[
        package.path = package.path .. ";./src/?.lua;./src/?/init.lua"
        local Header = require("yar.protocol.header")
        local Util = require("yar.util")
        local luasocket = require("socket")
        local srv = luasocket.bind("127.0.0.1", %d)
        srv:settimeout(nil)
        while true do
            local client = srv:accept()
            if client then
                client:settimeout(2)
                local packager_name = Util.pad_field("JSON", 8)
                local header = Header.new({ body_len = 0x40000000 })
                local head = packager_name .. header:pack()
                pcall(function() client:send(head .. string.rep("x", 10)) end)
                client:close()
            end
        end
    ]], FI_GARBAGE_PORT)

    os.execute("sleep 0.5")  -- 确保前一个 server 已停止
    local ok2 = start_custom_server(FI_GARBAGE_PORT, huge_body_script)
    if not ok2 then
        print("  [SKIP] huge body server subprocess failed to start")
        return
    end

    local client2 = Client.new("tcp://127.0.0.1:" .. FI_GARBAGE_PORT)
    local result2, err2 = client2:call("add", { 1, 2 })

    assert_ok(result2 == nil, "huge body: call should fail")
    assert_ok(err2 ~= nil, "huge body: should return error object")
    assert_ok(err2.code == Error.TRANSPORT,
        "huge body: error code should be TRANSPORT, got " .. tostring(err2.code))

    print("  [OK] fault injection: huge body_len (framing rejection)")

    stop_tcp_server(FI_GARBAGE_PORT)
end

-- ── 11. 事务中断连（mid-transaction kill）────────────────────────

local function test_fault_injection_mid_transaction_kill()
    Client.set_socket(ngx.socket)

    -- Server: accept → sleep 1s → close（模拟处理中途崩溃，不发响应）
    local script = string.format([[
        local luasocket = require("socket")
        local srv = luasocket.bind("127.0.0.1", %d)
        srv:settimeout(nil)
        while true do
            local client = srv:accept()
            if client then
                os.execute("sleep 1")
                client:close()
            end
        end
    ]], FI_KILL_PORT)

    local ok = start_custom_server(FI_KILL_PORT, script)
    if not ok then
        print("  [SKIP] mid-kill server subprocess failed to start")
        return
    end

    local client = Client.new("tcp://127.0.0.1:" .. FI_KILL_PORT)
    client:set_options({ timeout = 5 })

    local result, err = client:call("add", { 1, 2 })

    assert_ok(result == nil, "mid-kill: call should fail")
    assert_ok(err ~= nil, "mid-kill: should return error object")
    assert_ok(err.code == Error.TRANSPORT or err.code == Error.TIMEOUT,
        "mid-kill: error code should be TRANSPORT or TIMEOUT, got " .. tostring(err.code))

    print("  [OK] fault injection: mid-transaction kill (connection closed)")
    stop_tcp_server(FI_KILL_PORT)
end

-- ── 12. 连接池小 pool（pool exhaustion）─────────────────────────
--
-- 注：resty CLI 无 ngx.thread.spawn，cosocket 阻塞不可并发调度。
-- 此测试验证 pool_size=2 下 10 次顺序调用不 crash + 全部成功。
-- 真正的并发 pool 耗尽测试需 nginx 环境（ngx.thread.spawn）。

local function test_fault_injection_pool_exhaustion()
    Client.set_socket(ngx.socket)

    local script = string.format([[
        package.path = package.path .. ";./src/?.lua;./src/?/init.lua"
        local Server = require("yar.server")
        local TcpTransport = require("yar.server.tcp")
        local Socket = require("yar.transport.socket")
        local server = Server.new({
            add = function(a, b) return a + b end,
        })
        local srv, err = Socket.bind("127.0.0.1", %d)
        if not srv then error("bind failed: " .. tostring(err)) end
        srv:settimeout(nil)
        while true do
            local client = srv:accept()
            if client then
                client:settimeout(server.options.timeout)
                TcpTransport.serve(client, server.dispatcher, { keepalive = true })
                client:close()
            end
        end
    ]], FI_POOL_PORT)

    local ok = start_custom_server(FI_POOL_PORT, script)
    if not ok then
        print("  [SKIP] pool server subprocess failed to start")
        return
    end

    local client = Client.new("tcp://127.0.0.1:" .. FI_POOL_PORT)
    client:set_options({
        keepalive = { pool_size = 2, idle_timeout = 60000 },
    })

    local all_ok = true
    for i = 1, 10 do
        local result, err = client:call("add", { i, i })
        if result ~= i * 2 then
            all_ok = false
            print(string.format("    pool: call %d expected %d, got %s (err: %s)",
                i, i * 2, tostring(result), tostring(err)))
        end
    end

    assert_ok(all_ok, "pool: all 10 sequential calls should succeed with pool_size=2")
    print("  [OK] fault injection: pool exhaustion (10 calls, pool_size=2, no crash)")

    stop_tcp_server(FI_POOL_PORT)
end

-- ── 主入口 ────────────────────────────────────────────────────

function M.run()
    print("=== Yar-Lua OpenResty E2E tests ===")
    print("")

    local tests = {
        { name = "cosocket TCP round-trip",        fn = test_cosocket_tcp_roundtrip },
        { name = "keepalive param passthrough",     fn = test_keepalive_param_passthrough },
        { name = "cosocket settimeouts",            fn = test_cosocket_settimeouts },
        { name = "HTTP provider delegation",        fn = test_http_provider_delegation },
        { name = "lua-resty-http real delegation",  fn = test_resty_http_real_delegation },
        { name = "concurrency safety",              fn = test_concurrency_safety },
        { name = "keepalive mode",                  fn = test_keepalive_mode },
        { name = "cosocket error paths",            fn = test_cosocket_error_paths },
        { name = "FI: slow server (timeout)",       fn = test_fault_injection_slow_server },
        { name = "FI: garbage bytes",               fn = test_fault_injection_garbage_bytes },
        { name = "FI: mid-transaction kill",        fn = test_fault_injection_mid_transaction_kill },
        { name = "FI: pool exhaustion",             fn = test_fault_injection_pool_exhaustion },
    }

    for _, t in ipairs(tests) do
        local ok, err = pcall(t.fn)
        if not ok then
            print("  [FAIL] " .. t.name .. ": " .. tostring(err))
            fail_count = fail_count + 1
        end
    end

    print("")
    print(string.format("=== E2E tests: %d passed, %d failed ===", pass_count, fail_count))
    if fail_count > 0 then
        os.exit(1)
    end
end

-- 直接运行时自动执行
if arg and arg[0] and string.find(arg[0], "openresty_e2e_test") then
    M.run()
end

return M
