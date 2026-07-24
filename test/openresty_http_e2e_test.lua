-- test/openresty_http_e2e_test.lua
-- OpenResty HTTP 端到端测试：通过 cosocket / lua-resty-http 访问 nginx content_by_lua YAR server
--
-- 运行：resty test/openresty_http_e2e_test.lua
-- 前置：bash test/openresty_http_e2e.sh（启动 nginx）
--
-- 测试内容：
--   1. cosocket 客户端通过 HTTP 调用 YAR 服务端（content_by_lua 上下文）
--   2. lua-resty-http provider 委托真实 HTTP 往返
--   3. keepalive 连接池复用
--   4. 并发 HTTP 请求（多协程）
--   5. Msgpack packager over HTTP

local package_path = package.path
package.path = package_path .. ";./src/?.lua;./src/?/init.lua;./test/?.lua"

local Yar      = require("yar")
local Client   = Yar.client
local Packager = require("yar.packager.packager")

local SERVER_URL = "http://127.0.0.1:9702/api"

local pass_count = 0
local fail_count = 0

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

-- ── 1. cosocket HTTP 往返（content_by_lua）────────────────────

local function test_cosocket_http_roundtrip()
    Client.set_socket(ngx.socket)

    local client = Client.new(SERVER_URL)
    local result, err = client:call("add", { 10, 20 })
    assert_ok(result ~= nil, "http: call should succeed, err: " .. tostring(err))
    assert_eq(result, 30, "http: add(10,20) should return 30")

    local result2 = client:call("sub", { 50, 18 })
    assert_eq(result2, 32, "http: sub(50,18) should return 32")

    local result3 = client:call("echo", { "hello via http" })
    assert_eq(result3, "hello via http", "http: echo should return input")

    local result4 = client:call("greet", { "world" })
    assert_eq(result4, "hello, world", "http: greet('world') should return 'hello, world'")

    print("  [OK] cosocket HTTP round-trip (content_by_lua context)")
end

-- ── 2. lua-resty-http provider 委托 ──────────────────────────

local function test_resty_http_provider()
    local ok, resty_http = pcall(require, "resty.http")
    if not ok then
        print("  [SKIP] lua-resty-http not available")
        return
    end

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

    Client.set_http_provider(provider)

    local client = Client.new(SERVER_URL)
    local result, err = client:call("add", { 100, 200 })
    assert_ok(result ~= nil, "resty-http: call should succeed, err: " .. tostring(err))
    assert_eq(result, 300, "resty-http: add(100,200) should return 300")

    -- Msgpack over HTTP via resty-http
    client:setopt("packager", Packager.MSGPACK)
    local result2 = client:call("add", { 7, 8 })
    assert_eq(result2, 15, "resty-http: msgpack add(7,8) should return 15")

    Client.set_http_provider(nil)

    print("  [OK] lua-resty-http provider delegation (JSON + Msgpack)")
end

-- ── 3. keepalive 连接池复用 ──────────────────────────────────

local function test_http_keepalive()
    Client.set_socket(ngx.socket)

    local client = Client.new(SERVER_URL)

    -- 连续 10 次调用，验证连接池复用（不报错即成功）
    for i = 1, 10 do
        local result = client:call("add", { i, i })
        assert_eq(result, i * 2, "keepalive: add(" .. i .. "," .. i .. ") should return " .. (i * 2))
    end

    print("  [OK] HTTP keepalive (10 calls, connection pool reuse)")
end

-- ── 4. 并发 HTTP 请求 ────────────────────────────────────────

local function test_http_concurrency()
    Client.set_socket(ngx.socket)

    local client = Client.new(SERVER_URL)
    local results = {}
    local errors = {}

    -- 10 个协程并发 HTTP 请求
    -- resty CLI 无 ngx.thread，用 Lua 协程模拟并发
    local coroutines = {}
    for i = 1, 10 do
        coroutines[i] = coroutine.create(function(idx)
            local result, err = client:call("add", { idx, idx * 10 })
            if result then
                results[idx] = result
            else
                errors[idx] = err
            end
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

    local all_ok = true
    for i = 1, 10 do
        local expected = i + i * 10
        if results[i] ~= expected then
            all_ok = false
            print(string.format("    concurrency: thread %d expected %d, got %s (err: %s)",
                i, expected, tostring(results[i]), tostring(errors[i])))
        end
    end
    assert_ok(all_ok, "concurrency: all 10 HTTP coroutines should return correct results")
    print("  [OK] HTTP concurrency (10 coroutines, content_by_lua reentrant)")
end

-- ── 5. 错误路径（未知方法）──────────────────────────────────

local function test_http_error_path()
    Client.set_socket(ngx.socket)

    local client = Client.new(SERVER_URL)
    local result, err = client:call("nonexistent_method", { 1, 2 })
    assert_ok(result == nil, "error: unknown method should return nil")
    assert_ok(err ~= nil, "error: should return error object")

    local Error = require("yar.error")
    assert_eq(err.code, Error.NOT_FOUND, "error: unknown method should return NOT_FOUND code")

    print("  [OK] HTTP error path (unknown method → NOT_FOUND)")
end

-- ── 主入口 ────────────────────────────────────────────────────

local function run()
    print("=== Yar-Lua HTTP E2E tests (nginx content_by_lua) ===")
    print("")

    local tests = {
        { name = "cosocket HTTP round-trip",      fn = test_cosocket_http_roundtrip },
        { name = "lua-resty-http provider",        fn = test_resty_http_provider },
        { name = "HTTP keepalive",                 fn = test_http_keepalive },
        { name = "HTTP concurrency",               fn = test_http_concurrency },
        { name = "HTTP error path",               fn = test_http_error_path },
    }

    for _, t in ipairs(tests) do
        local ok, err = pcall(t.fn)
        if not ok then
            print("  [FAIL] " .. t.name .. ": " .. tostring(err))
            fail_count = fail_count + 1
        end
    end

    print("")
    print(string.format("=== HTTP E2E tests: %d passed, %d failed ===", pass_count, fail_count))
    if fail_count > 0 then
        os.exit(1)
    end
end

run()
