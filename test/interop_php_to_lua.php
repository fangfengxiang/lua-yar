<?php
// test/interop_php_to_lua.php
// 互操作测试：PHP 客户端 → Lua Yar 服务端
// 前置：lua test/interop_lua_server.lua（由 interop.sh 启动）
// 运行：php test/interop_php_to_lua.php
//
// 测试场景（JSON + Msgpack 两个 packager 都覆盖）：
//   1. JSON packager：add / sub / upper / greet
//   2. Msgpack packager：add / sub / upper / greet

$LUA_HTTP_PORT = getenv("LUA_HTTP_PORT") ?: "9801";
$LUA_SERVER_URL = "http://127.0.0.1:$LUA_HTTP_PORT/";

$pass_count = 0;
$fail_count = 0;

function assert_ok($cond, $msg = "") {
    global $pass_count, $fail_count;
    if (!$cond) {
        $fail_count++;
        fwrite(STDERR, "ASSERT FAILED: " . ($msg ?: "expression is false") . "\n");
        exit(1);
    }
    $pass_count++;
}

function assert_eq($a, $b, $msg = "") {
    global $pass_count, $fail_count;
    if ($a !== $b) {
        $fail_count++;
        fwrite(STDERR, sprintf("ASSERT FAILED: %s (expected %s, got %s)\n",
            $msg ?: "mismatch", var_export($b, true), var_export($a, true)));
        exit(1);
    }
    $pass_count++;
}

// ── 1. JSON packager ──────────────────────────────────────────

function test_json_packager($url) {
    global $pass_count, $fail_count;
    $client = new Yar_Client($url);
    $client->SetOpt(YAR_OPT_PACKAGER, "json");

    $r1 = $client->add(10, 20);
    assert_ok($r1 !== null, "json: add should succeed");
    assert_eq($r1, 30, "json: add(10,20) should return 30");

    $r2 = $client->sub(50, 18);
    assert_eq($r2, 32, "json: sub(50,18) should return 32");

    $r3 = $client->upper("hello");
    assert_eq($r3, "HELLO", "json: upper('hello') should return 'HELLO'");

    $r4 = $client->greet("world");
    assert_eq($r4, "hello, world", "json: greet('world') should return 'hello, world'");

    echo "  [OK] PHP → Lua (JSON packager: add/sub/upper/greet)\n";
}

// ── 2. Msgpack packager ───────────────────────────────────────

function test_msgpack_packager($url) {
    global $pass_count, $fail_count;
    $client = new Yar_Client($url);
    $client->SetOpt(YAR_OPT_PACKAGER, "msgpack");

    $r1 = $client->add(100, 200);
    assert_ok($r1 !== null, "msgpack: add should succeed");
    assert_eq($r1, 300, "msgpack: add(100,200) should return 300");

    $r2 = $client->sub(100, 1);
    assert_eq($r2, 99, "msgpack: sub(100,1) should return 99");

    $r3 = $client->upper("php");
    assert_eq($r3, "PHP", "msgpack: upper('php') should return 'PHP'");

    $r4 = $client->greet("lua");
    assert_eq($r4, "hello, lua", "msgpack: greet('lua') should return 'hello, lua'");

    echo "  [OK] PHP → Lua (Msgpack packager: add/sub/upper/greet)\n";
}

// ── 主入口 ────────────────────────────────────────────────────

echo "=== PHP client → Lua server (interop) ===\n";
echo "\n";

test_json_packager($LUA_SERVER_URL);
test_msgpack_packager($LUA_SERVER_URL);

echo "\n";
echo "=== PHP → Lua interop: {$pass_count} passed, {$fail_count} failed ===\n";

if ($fail_count > 0) {
    exit(1);
}
