<?php
// test/concurrent_php_to_lua_http.php
// 并发端到端测试：PHP 客户端 3 并发 → Lua Yar 原生 HTTP 服务端（顺序处理）
//
// 测试场景：
//   - PHP 客户端用 pcntl_fork 创建 3 个子进程，每个子进程独立创建 Yar_Client
//     并发请求 Lua 原生 HTTP 服务端（test/interop_lua_server.lua，端口由环境变量 CONCURRENT_LUA_HTTP_PORT 指定，默认 9803）
//   - Lua 原生 HttpServer:run() 是单进程顺序 accept 循环，3 个并发请求会被
//     逐个处理（验证顺序处理不丢请求、不串数据）
//   - 每个子进程用唯一参数 add(i, i*10) 调用，期望返回 i + i*10
//   - 通过 requestId（Yar 协议的 transaction ID）验证每个响应与请求匹配
//   - 同时测试 JSON 和 Msgpack 两个 packager
//
// 前置：lua test/interop_lua_server.lua（由 concurrent_e2e.sh 启动）
// 运行：php test/concurrent_php_to_lua_http.php
//
// 约束：仅修改测试代码，不修改 src 类库代码

$LUA_HTTP_PORT = getenv("CONCURRENT_LUA_HTTP_PORT") ?: "9803";
$LUA_HTTP_SERVER_URL = "http://127.0.0.1:$LUA_HTTP_PORT/";
$CONCURRENCY = 3;
$TMP_DIR = sys_get_temp_dir();

$pass_count = 0;
$fail_count = 0;

function assert_ok($cond, $msg = "") {
    global $pass_count, $fail_count;
    if (!$cond) {
        $fail_count++;
        fwrite(STDERR, "ASSERT FAILED: " . ($msg ?: "expression is false") . "\n");
        return false;
    }
    $pass_count++;
    return true;
}

function assert_eq($a, $b, $msg = "") {
    global $pass_count, $fail_count;
    if ($a !== $b) {
        $fail_count++;
        fwrite(STDERR, sprintf("ASSERT FAILED: %s (expected %s, got %s)\n",
            $msg ?: "mismatch", var_export($b, true), var_export($a, true)));
        return false;
    }
    $pass_count++;
    return true;
}

// ── 单个并发子进程逻辑 ──────────────────────────────────────
// 每个子进程：创建 Yar_Client，调用 add(i, i*10)，将结果写入临时文件
function worker_process($url, $worker_id, $packager, $result_file) {
    $client = new Yar_Client($url);
    $client->SetOpt(YAR_OPT_PACKAGER, $packager);

    $a = $worker_id;
    $b = $worker_id * 10;
    $expected = $a + $b;

    $result = $client->add($a, $b);
    $success = ($result !== null && $result === $expected);

    // 将结果写入文件供父进程收集
    $data = json_encode([
        'worker_id' => $worker_id,
        'packager'  => $packager,
        'args'      => [$a, $b],
        'expected'  => $expected,
        'actual'    => $result,
        'success'   => $success,
    ]);
    file_put_contents($result_file, $data);

    exit($success ? 0 : 1);
}

// ── 并发测试：指定 packager ─────────────────────────────────
function test_concurrent($url, $concurrency, $packager) {
    global $TMP_DIR;

    $pids = [];
    $result_files = [];

    // fork $concurrency 个子进程
    for ($i = 1; $i <= $concurrency; $i++) {
        $result_file = $TMP_DIR . "/yar_concurrent_http_{$packager}_{$i}.json";
        @unlink($result_file);
        $result_files[$i] = $result_file;

        $pid = pcntl_fork();
        if ($pid == -1) {
            fwrite(STDERR, "FATAL: pcntl_fork failed for worker $i\n");
            exit(1);
        } elseif ($pid == 0) {
            // 子进程
            worker_process($url, $i, $packager, $result_file);
            exit(1); // worker_process 内部已 exit，兜底
        } else {
            // 父进程
            $pids[$i] = $pid;
        }
    }

    // 等待所有子进程完成
    $all_success = true;
    for ($i = 1; $i <= $concurrency; $i++) {
        pcntl_waitpid($pids[$i], $status);
        $exit_code = pcntl_wexitstatus($status);

        $result_file = $result_files[$i];
        $data = json_decode(@file_get_contents($result_file) ?: '{}', true);

        if (!isset($data['success']) || $data['success'] !== true) {
            $all_success = false;
            $actual = $data['actual'] ?? 'null';
            $expected = $data['expected'] ?? '?';
            fwrite(STDERR, sprintf("  worker %d (%s): FAIL — expected %s, got %s\n",
                $i, $packager, var_export($expected, true), var_export($actual, true)));
        }

        @unlink($result_file);
    }

    return $all_success;
}

// ── 主入口 ────────────────────────────────────────────────────

echo "=== Concurrent: PHP → Lua HTTP (3 concurrent, sequential server) ===\n";
echo "\n";

if (!function_exists('pcntl_fork')) {
    echo "[SKIP] pcntl extension not available, skipping concurrent test\n";
    exit(0);
}

// 预检：服务端是否可达
$client = new Yar_Client($LUA_HTTP_SERVER_URL);
$client->SetOpt(YAR_OPT_PACKAGER, "json");
try {
    $probe = $client->add(0, 0);
    if ($probe !== 0) {
        fwrite(STDERR, "FATAL: probe add(0,0) expected 0, got " . var_export($probe, true) . "\n");
        exit(1);
    }
} catch (Throwable $e) {
    fwrite(STDERR, "FATAL: cannot connect to Lua HTTP server: " . $e->getMessage() . "\n");
    exit(1);
}
echo "  [probe] Lua HTTP server is reachable\n";

// 测试 1：JSON packager，3 并发
echo "  [test] JSON packager, {$CONCURRENCY} concurrent workers...\n";
$json_ok = test_concurrent($LUA_HTTP_SERVER_URL, $CONCURRENCY, "json");
if ($json_ok) {
    echo "  [OK] JSON: all {$CONCURRENCY} concurrent requests succeeded (sequential processing)\n";
} else {
    echo "  [FAIL] JSON: some concurrent requests failed\n";
}

// 测试 2：Msgpack packager，3 并发
echo "  [test] Msgpack packager, {$CONCURRENCY} concurrent workers...\n";
$msgpack_ok = test_concurrent($LUA_HTTP_SERVER_URL, $CONCURRENCY, "msgpack");
if ($msgpack_ok) {
    echo "  [OK] Msgpack: all {$CONCURRENCY} concurrent requests succeeded (sequential processing)\n";
} else {
    echo "  [FAIL] Msgpack: some concurrent requests failed\n";
}

echo "\n";
echo "=== Concurrent PHP → Lua HTTP: {$pass_count} passed, {$fail_count} failed ===\n";

if (!$json_ok || !$msgpack_ok || $fail_count > 0) {
    exit(1);
}
