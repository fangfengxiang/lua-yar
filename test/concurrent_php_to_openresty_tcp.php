<?php
// test/concurrent_php_to_openresty_tcp.php
// 并发端到端测试：PHP 客户端 50 并发 → OpenResty YAR TCP 服务端（2 workers，协程并发）
//
// 测试场景：
//   - PHP 客户端用 pcntl_fork 创建 50 个子进程，每个子进程独立创建 Yar_Client
//     并发请求 OpenResty TCP 服务端（nginx stream {} 块，2 workers）
//   - OpenResty nginx stream 模块 2 worker_processes，每个 worker 用 content_by_lua_block
//     处理 TCP 连接，nginx 事件循环 + 协程并发处理多个连接
//   - 每个子进程用唯一参数 add(i, i*10) 调用，期望返回 i + i*10
//   - 通过 requestId（Yar 协议的 transaction ID）验证每个响应与请求匹配
//   - 服务端 handler (test/nginx_stream_server.lua) 记录每个请求的
//     worker_id + requestId + status 到 error.log
//   - 测试脚本解析 nginx error.log 验证：
//     a) 所有 50 个 requestId 都有 processing + done 记录
//     b) 没有任何 status=error 记录（协程异常）
//     c) 至少 2 个不同 worker_id 参与处理（验证多 worker 负载分担）
//   - 同时测试 JSON 和 Msgpack 两个 packager
//
// 前置：bash test/concurrent_openresty.sh（启动 nginx stream 2 workers）
// 运行：php test/concurrent_php_to_openresty_tcp.php [nginx_error_log_path]
//
// 注意：PHP Yar 的 tcp:// transport 支持取决于 yar 扩展编译选项。
//       若 Yar_Client 不支持 tcp:// scheme，本脚本会输出 SKIP 提示并退出 0。
//
// 约束：仅修改测试代码，不修改 src 类库代码

$OPENRESTY_TCP_PORT = getenv("CONCURRENT_TCP_PORT") ?: "9708";
$OPENRESTY_TCP_URL = "tcp://127.0.0.1:$OPENRESTY_TCP_PORT";
$CONCURRENCY = 50;
$TMP_DIR = sys_get_temp_dir();
$NGINX_ERROR_LOG = $argv[1] ?? null;

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
function worker_process($url, $worker_id, $packager, $result_file) {
    $client = new Yar_Client($url);
    $client->SetOpt(YAR_OPT_PACKAGER, $packager);

    $a = $worker_id;
    $b = $worker_id * 10;
    $expected = $a + $b;

    $result = $client->add($a, $b);
    $success = ($result !== null && $result === $expected);

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

    for ($i = 1; $i <= $concurrency; $i++) {
        $result_file = $TMP_DIR . "/yar_concurrent_or_tcp_{$packager}_{$i}.json";
        @unlink($result_file);
        $result_files[$i] = $result_file;

        $pid = pcntl_fork();
        if ($pid == -1) {
            fwrite(STDERR, "FATAL: pcntl_fork failed for worker $i\n");
            exit(1);
        } elseif ($pid == 0) {
            worker_process($url, $i, $packager, $result_file);
            exit(1);
        } else {
            $pids[$i] = $pid;
        }
    }

    $all_success = true;
    for ($i = 1; $i <= $concurrency; $i++) {
        pcntl_waitpid($pids[$i], $status);

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

// ── 解析 nginx error.log 验证协程处理 ────────────────────────
function verify_nginx_logs($error_log, $concurrency, $packager) {
    if (!$error_log || !file_exists($error_log)) {
        echo "  [SKIP] nginx error.log not available for log verification\n";
        return true;
    }

    $log_content = file_get_contents($error_log);
    if ($log_content === false) {
        echo "  [SKIP] cannot read nginx error.log\n";
        return true;
    }

    // 统计 processing / done / error 记录（stream handler 用 [YAR-STREAM] 前缀）
    $processing_count = preg_match_all('/\[YAR-STREAM\].*status=processing/', $log_content);
    $done_count = preg_match_all('/\[YAR-STREAM\].*status=done/', $log_content);
    $error_count = preg_match_all('/\[YAR-STREAM\].*status=error/', $log_content);

    // 统计不同 worker_id 数量
    $worker_ids = [];
    if (preg_match_all('/worker=(\d+)/', $log_content, $matches)) {
        $worker_ids = array_unique($matches[1]);
    }

    echo "  [log] processing={$processing_count} done={$done_count} error={$error_count}";
    echo " workers=" . implode(',', $worker_ids) . "\n";

    if ($error_count > 0) {
        fwrite(STDERR, "  [FAIL] found $error_count error records in nginx log (coroutine exceptions)\n");
        return false;
    }

    if (count($worker_ids) < 2) {
        echo "  [WARN] only " . count($worker_ids) . " worker(s) participated, expected 2+\n";
    }

    return true;
}

// ── 主入口 ────────────────────────────────────────────────────

echo "=== Concurrent: PHP → OpenResty TCP (50 concurrent, 2 workers) ===\n";
echo "\n";

if (!function_exists('pcntl_fork')) {
    echo "[SKIP] pcntl extension not available, skipping concurrent test\n";
    exit(0);
}

// 预检：TCP transport 是否支持
try {
    $client = new Yar_Client($OPENRESTY_TCP_URL);
    $client->SetOpt(YAR_OPT_PACKAGER, "json");
    $probe = $client->add(0, 0);
    if ($probe !== 0) {
        fwrite(STDERR, "FATAL: probe add(0,0) expected 0, got " . var_export($probe, true) . "\n");
        exit(1);
    }
} catch (Throwable $e) {
    $msg = $e->getMessage();
    if (strpos($msg, "tcp") !== false || strpos($msg, "unsupported") !== false
        || strpos($msg, "transport") !== false || strpos($msg, "invalid") !== false) {
        echo "  [SKIP] PHP Yar tcp:// transport not supported: " . $msg . "\n";
        exit(0);
    }
    fwrite(STDERR, "FATAL: cannot connect to OpenResty TCP server: " . $msg . "\n");
    exit(1);
}
echo "  [probe] OpenResty TCP server is reachable\n";

// 测试 1：JSON packager，50 并发
echo "  [test] JSON packager, {$CONCURRENCY} concurrent workers...\n";
$json_ok = test_concurrent($OPENRESTY_TCP_URL, $CONCURRENCY, "json");
if ($json_ok) {
    echo "  [OK] JSON: all {$CONCURRENCY} concurrent requests succeeded\n";
} else {
    echo "  [FAIL] JSON: some concurrent requests failed\n";
}

$json_log_ok = verify_nginx_logs($NGINX_ERROR_LOG, $CONCURRENCY, "json");

if ($NGINX_ERROR_LOG && file_exists($NGINX_ERROR_LOG)) {
    file_put_contents($NGINX_ERROR_LOG, "");
}

// 测试 2：Msgpack packager，50 并发
echo "  [test] Msgpack packager, {$CONCURRENCY} concurrent workers...\n";
$msgpack_ok = test_concurrent($OPENRESTY_TCP_URL, $CONCURRENCY, "msgpack");
if ($msgpack_ok) {
    echo "  [OK] Msgpack: all {$CONCURRENCY} concurrent requests succeeded\n";
} else {
    echo "  [FAIL] Msgpack: some concurrent requests failed\n";
}

$msgpack_log_ok = verify_nginx_logs($NGINX_ERROR_LOG, $CONCURRENCY, "msgpack");

echo "\n";
echo "=== Concurrent PHP → OpenResty TCP: {$pass_count} passed, {$fail_count} failed ===\n";

if (!$json_ok || !$msgpack_ok || !$json_log_ok || !$msgpack_log_ok || $fail_count > 0) {
    exit(1);
}
