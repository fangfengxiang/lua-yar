-- test/interop_lua_to_lua_tcp.lua
-- 互操作测试：Lua 客户端 → Lua Yar TCP 服务端
-- 前置：lua test/interop_lua_tcp_server.lua（由 interop.sh 启动）
-- 运行：lua test/interop_lua_to_lua_tcp.lua
--
-- 测试场景（JSON + Msgpack 两个 packager 都覆盖）：
--   1. JSON packager：add / sub / upper / greet
--   2. Msgpack packager：add / sub / upper / greet
--   3. persistent 模式（TCP 连接复用）
--
-- 验证 TCP transport 自身的互操作性（不依赖 PHP）。

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local Yar      = require("yar")
local Client   = Yar.client
local Packager = require("yar.packager.packager")

local LUA_TCP_SERVER_URL = "tcp://127.0.0.1:9802"

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

-- ── 1. JSON packager ──────────────────────────────────────────

local function test_json_packager()
    local client = Client.new(LUA_TCP_SERVER_URL)
    client:setopt("packager", Packager.JSON)

    local r1, err1 = client:call("add", { 10, 20 })
    assert_ok(r1 ~= nil, "json: add should succeed, err: " .. tostring(err1))
    assert_eq(r1, 30, "json: add(10,20) should return 30")

    local r2 = client:call("sub", { 50, 18 })
    assert_eq(r2, 32, "json: sub(50,18) should return 32")

    local r3 = client:call("upper", { "hello" })
    assert_eq(r3, "HELLO", "json: upper('hello') should return 'HELLO'")

    local r4 = client:call("greet", { "world" })
    assert_eq(r4, "hello, world", "json: greet('world') should return 'hello, world'")

    print("  [OK] Lua → Lua TCP (JSON packager: add/sub/upper/greet)")
end

-- ── 2. Msgpack packager ───────────────────────────────────────

local function test_msgpack_packager()
    local client = Client.new(LUA_TCP_SERVER_URL)
    client:setopt("packager", Packager.MSGPACK)

    local r1, err1 = client:call("add", { 100, 200 })
    assert_ok(r1 ~= nil, "msgpack: add should succeed, err: " .. tostring(err1))
    assert_eq(r1, 300, "msgpack: add(100,200) should return 300")

    local r2 = client:call("sub", { 100, 1 })
    assert_eq(r2, 99, "msgpack: sub(100,1) should return 99")

    local r3 = client:call("upper", { "lua" })
    assert_eq(r3, "LUA", "msgpack: upper('lua') should return 'LUA'")

    local r4 = client:call("greet", { "tcp" })
    assert_eq(r4, "hello, tcp", "msgpack: greet('tcp') should return 'hello, tcp'")

    print("  [OK] Lua → Lua TCP (Msgpack packager: add/sub/upper/greet)")
end

-- ── 3. persistent 模式（TCP 连接复用）────────────────────────

local function test_persistent_mode()
    local client = Client.new(LUA_TCP_SERVER_URL)
    client:setopt("packager", Packager.JSON)
    client:setopt("persistent", true)

    -- 同一 client 连续调用，复用 TCP 连接
    local r1 = client:call("add", { 1, 2 })
    assert_eq(r1, 3, "persistent: add(1,2) should return 3")

    local r2 = client:call("add", { 10, 20 })
    assert_eq(r2, 30, "persistent: add(10,20) should return 30")

    local r3 = client:call("add", { 100, 200 })
    assert_eq(r3, 300, "persistent: add(100,200) should return 300")

    print("  [OK] Lua → Lua TCP (persistent mode: 3 calls reuse connection)")
end

-- ── 主入口 ────────────────────────────────────────────────────

local function run()
    print("=== Lua client → Lua TCP server (interop) ===")
    print("")

    local tests = {
        { name = "JSON packager",           fn = test_json_packager },
        { name = "Msgpack packager",        fn = test_msgpack_packager },
        { name = "persistent mode (TCP)",   fn = test_persistent_mode },
    }

    for _, t in ipairs(tests) do
        local ok, err = pcall(t.fn)
        if not ok then
            print("  [FAIL] " .. t.name .. ": " .. tostring(err))
            fail_count = fail_count + 1
        end
    end

    print("")
    print(string.format("=== Lua → Lua TCP interop: %d passed, %d failed ===", pass_count, fail_count))
    if fail_count > 0 then
        os.exit(1)
    end
end

run()
