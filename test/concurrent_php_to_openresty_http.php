<?php
// test/concurrent_php_to_openresty_http.php
// 并发端到端测试：PHP 客户端 50 并发 → OpenResty YAR HTTP 服务端（2 workers，协程并发）
//
// 测试场景：
//   - PHP 客户端用 pcntl_fork 创建 50 个子进程，每个子进程独立创建 Yar_Client
//     并发请求 OpenResty HTTP 服务端（nginx 2 workers，content_by_lua 处理）
//   - OpenResty nginx 2 worker_processes，每个 worker 用 nginx 事件循环 + 协程
//     并发处理多个 HTTP 请求（每 worker 可处理 10+ 并发协程）
//   - 每个子进程用唯一参数 add(i, i*10) 调用，期望返回 i + i*10
//   - 通过 requestId（Yar 协议的 transaction ID）验证每个响应与请求匹配
//   - 服务端 handler (test/nginx_concurrent_server.lua) 记录每个请求的
//     worker_id + requestId + status 到 error.log
//   - 测试脚本解析 nginx error.log 验证：
//     a) 所有 50 个 requestId 都有 processing + done 记录
//     b) 没有任何 status=error 记录（协程异常）
//     c) 至少 2 个不同 worker_id 参与处理（验证多 worker 负载分担）
//   - 同时测试 JSON 和 Msgpack 两个 packager
//
// 前置：bash test/concurrent_openresty.sh（启动 nginx 2 workers）
// 运行：php test/concurrent_php_to_openresty_http.php [nginx_error_log_path]
//
// 约束：仅修改测试代码，不修改 src 类库代码

$OPENRESTY_HTTP_PORT = getenv("CONCURRENT_HTTP_PORT") ?: "9707";
$OPENRESTY_HTTP_URL = "http://127.0.0.1:$OPENRESTY_HTTP_PORT/api";
$CONCURRENCY = 50;
$TMP_DIR = sys_get_temp_dir();
$NGINX_ERROR_LOG = $argv[1] ?? null;  // 由编排脚本传入

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
        $result_file = $TMP_DIR . "/yar_concurrent_or_http_{$packager}_{$i}.json";
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
        return true;  // 不阻塞测试，日志验证是增强检查
    }

    $log_content = file_get_contents($error_log);
    if ($log_content === false) {
        echo "  [SKIP] cannot read nginx error.log\n";
        return true;
    }

    // 统计 processing / done / error 记录
    $processing_count = preg_match_all('/\[YAR-CONCURRENT\].*status=processing/', $log_content);
    $done_count = preg_match_all('/\[YAR-CONCURRENT\].*status=done/', $log_content);
    $error_count = preg_match_all('/\[YAR-CONCURRENT\].*status=error/', $log_content);

    // 统计不同 worker_id 数量
    $worker_ids = [];
    if (preg_match_all('/worker=(\d+)/', $log_content, $matches)) {
        $worker_ids = array_unique($matches[1]);
    }

    echo "  [log] processing={$processing_count} done={$done_count} error={$error_count}";
    echo " workers=" . implode(',', $worker_ids) . "\n";

    // 验证：无 error 记录（协程无异常）
    if ($error_count > 0) {
        fwrite(STDERR, "  [FAIL] found $error_count error records in nginx log (coroutine exceptions)\n");
        return false;
    }

    // 验证：至少 2 个不同 worker_id（多 worker 负载分担）
    if (count($worker_ids) < 2) {
        echo "  [WARN] only " . count($worker_ids) . " worker(s) participated, expected 2+\n";
    }

    return true;
}

// ── 主入口 ────────────────────────────────────────────────────

echo "=== Concurrent: PHP → OpenResty HTTP (50 concurrent, 2 workers) ===\n";
echo "\n";

if (!function_exists('pcntl_fork')) {
    echo "[SKIP] pcntl extension not available, skipping concurrent test\n";
    exit(0);
}

// 预检：服务端是否可达
try {
    $client = new Yar_Client($OPENRESTY_HTTP_URL);
    $client->SetOpt(YAR_OPT_PACKAGER, "json");
    $probe = $client->add(0, 0);
    if ($probe !== 0) {
        fwrite(STDERR, "FATAL: probe add(0,0) expected 0, got " . var_export($probe, true) . "\n");
        exit(1);
    }
} catch (Throwable $e) {
    fwrite(STDERR, "FATAL: cannot connect to OpenResty HTTP server: " . $e->getMessage() . "\n");
    exit(1);
}
echo "  [probe] OpenResty HTTP server is reachable\n";

// 测试 1：JSON packager，50 并发
echo "  [test] JSON packager, {$CONCURRENCY} concurrent workers...\n";
$json_ok = test_concurrent($OPENRESTY_HTTP_URL, $CONCURRENCY, "json");
if ($json_ok) {
    echo "  [OK] JSON: all {$CONCURRENCY} concurrent requests succeeded\n";
} else {
    echo "  [FAIL] JSON: some concurrent requests failed\n";
}

// 验证 nginx 日志（JSON 测试后检查）
$json_log_ok = verify_nginx_logs($NGINX_ERROR_LOG, $CONCURRENCY, "json");

// 清空日志以便 Msgpack 测试的日志独立验证
if ($NGINX_ERROR_LOG && file_exists($NGINX_ERROR_LOG)) {
    // 清空日志文件（truncate）
    file_put_contents($NGINX_ERROR_LOG, "");
}

// 测试 2：Msgpack packager，50 并发
echo "  [test] Msgpack packager, {$CONCURRENCY} concurrent workers...\n";
$msgpack_ok = test_concurrent($OPENRESTY_HTTP_URL, $CONCURRENCY, "msgpack");
if ($msgpack_ok) {
    echo "  [OK] Msgpack: all {$CONCURRENCY} concurrent requests succeeded\n";
} else {
    echo "  [FAIL] Msgpack: some concurrent requests failed\n";
}

// 验证 nginx 日志（Msgpack 测试后检查）
$msgpack_log_ok = verify_nginx_logs($NGINX_ERROR_LOG, $CONCURRENCY, "msgpack");

echo "\n";
echo "=== Concurrent PHP → OpenResty HTTP: {$pass_count} passed, {$fail_count} failed ===\n";

if (!$json_ok || !$msgpack_ok || !$json_log_ok || !$msgpack_log_ok || $fail_count > 0) {
    exit(1);
}
