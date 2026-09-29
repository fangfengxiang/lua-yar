<?php
// test/e2e/php_client.php
// E2E 测试共享 PHP 客户端：调用 add(a,b)，断言 a+b=c
//
// 用法：php test/e2e/php_client.php <url> <packager>
//   url:      服务端地址（http://... 或 tcp://...）
//   packager: "json" 或 "msgpack"
//
// 测试用例（每组 packager 都跑）：
//   add(10, 20)    = 30
//   add(100, 200)  = 300
//   add(1, 2)      = 3
//   add(0, 0)      = 0
//
// 退出码：0=全部通过，1=有失败

$url      = $argv[1] ?? exit("usage: php_client.php <url> <packager>\n");
$pkg_name = $argv[2] ?? exit("usage: php_client.php <url> <packager>\n");

$cases = [
    [10,  20,  30],
    [100, 200, 300],
    [1,   2,   3],
    [0,   0,   0],
];

$pass = 0;
$fail = 0;

try {
    $client = new Yar_Client($url);
    $client->SetOpt(YAR_OPT_PACKAGER, $pkg_name);

    foreach ($cases as $c) {
        [$a, $b, $expect] = $c;
        $r = $client->add($a, $b);
        if ($r === null) {
            fwrite(STDERR, sprintf("  [FAIL] %s add(%d,%d): err=null\n", $pkg_name, $a, $b));
            $fail++;
        } elseif ($r !== $expect) {
            fwrite(STDERR, sprintf("  [FAIL] %s add(%d,%d): expected %d, got %s\n",
                $pkg_name, $a, $b, $expect, var_export($r, true)));
            $fail++;
        } else {
            $pass++;
        }
    }
} catch (Throwable $e) {
    fwrite(STDERR, sprintf("  [FAIL] %s fatal: %s\n", $pkg_name, $e->getMessage()));
    $fail++;
}

$tag = $fail === 0 ? "OK" : "FAIL";
echo sprintf("  [%s] %s add: %d passed, %d failed\n", $tag, $pkg_name, $pass, $fail);
exit($fail > 0 ? 1 : 0);
