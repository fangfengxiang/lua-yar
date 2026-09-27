<?php
// test/diag_php_wire_layout.php
// 捕获 PHP Yar client 发出的原始 HTTP POST body，dump hex
//
// 运行：php test/diag_php_wire_layout.php
//
// 原理：启动一个本地 HTTP server 接收 Yar client 的请求，
// dump 收到的 raw body 的前 90 字节 hex。

// 使用 stream_socket_server 作为捕获 server
$port = 9899;
$server = stream_socket_server("tcp://127.0.0.1:$port", $errno, $errstr);
if (!$server) {
    fwrite(STDERR, "Failed to create server: $errstr\n");
    exit(1);
}

// 在子进程中启动 Yar client 发请求
$pid = pcntl_fork();
if ($pid == -1) {
    fwrite(STDERR, "fork failed\n");
    exit(1);
}

if ($pid == 0) {
    // 子进程：Yar client 发请求
    usleep(100000); // 等 server ready
    try {
        $client = new Yar_Client("http://127.0.0.1:$port/");
        $client->SetOpt(YAR_OPT_PACKAGER, "json");
        @$client->add(10, 20);
    } catch (Throwable $e) {
        // 预期会失败（server 不会正常响应）
    }
    exit(0);
}

// 父进程：接收请求，dump raw body
$conn = @stream_socket_accept($server, 3);
if (!$conn) {
    fwrite(STDERR, "No connection received\n");
    exit(1);
}

// 读取 HTTP 请求
$raw = stream_get_contents($conn);

// 找到 body（\r\n\r\n 之后）
$pos = strpos($raw, "\r\n\r\n");
if ($pos === false) {
    fwrite(STDERR, "No HTTP body found\n");
    exit(1);
}

$body = substr($raw, $pos + 4);

// dump hex
echo "=== PHP Yar client raw request body (" . strlen($body) . " bytes) ===\n\n";
for ($i = 0; $i < min(strlen($body), 90); $i += 16) {
    $hexParts = [];
    $asciiParts = [];
    for ($j = $i; $j < min($i + 16, strlen($body)); $j++) {
        $b = ord($body[$j]);
        $hexParts[] = sprintf("%02X", $b);
        $asciiParts[] = ($b >= 32 && $b <= 126) ? $body[$j] : ".";
    }
    $offsetStr = sprintf("%04X", $i);
    $hexStr = implode(" ", $hexParts);
    $hexStr = str_pad($hexStr, 47);
    $asciiStr = implode("", $asciiParts);
    printf("  %s  %s  |%s|\n", $offsetStr, $hexStr, $asciiStr);
}

// 解析 header 字段（PHP Yar layout: header at offset 0）
echo "\n--- PHP Yar parsed fields (header at offset 0) ---\n";
if (strlen($body) >= 82) {
    $id        = unpack("N", substr($body, 0, 4))[1];
    $version   = unpack("n", substr($body, 4, 2))[1];
    $magic     = unpack("N", substr($body, 6, 4))[1];
    $reserved  = unpack("N", substr($body, 10, 4))[1];
    $provider  = rtrim(substr($body, 14, 32), "\0");
    $token     = rtrim(substr($body, 46, 32), "\0");
    $body_len  = unpack("N", substr($body, 78, 4))[1];
    $pkg_name  = rtrim(substr($body, 82, 8), "\0");

    printf("  header.id:        %d\n", $id);
    printf("  header.version:   %d\n", $version);
    printf("  header.magic_num: 0x%08X (expected 0x%08X)\n", $magic, 0x80DFEC60);
    printf("  header.reserved:  %d\n", $reserved);
    printf("  header.provider:  %s\n", $provider);
    printf("  header.token:     %s\n", $token ? $token : "(empty)");
    printf("  header.body_len:  %d\n", $body_len);
    printf("  packager_name:    %s\n", $pkg_name);
    printf("  actual body+pkg:  %d bytes (body_len should = 8 + body)\n", strlen($body) - 82);
    printf("  body_len == 8 + body_len? %s\n",
        ($body_len == strlen($body) - 82) ? "YES (includes packager name)" : "NO");
}

// 对比
echo "\n=== Layout comparison ===\n";
echo "  PHP Yar:   [header:82][packager_name:8][body]  body_len = 8 + body\n";
echo "  lua-yar:   [packager_name:8][header:82][body]  body_len = body only\n";
echo "  COMPATIBLE? NO — header and packager_name positions are swapped\n";

pcntl_waitpid($pid, $status);
fclose($server);
