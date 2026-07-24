<?php
// test/server.php
// PHP Yar 服务端（互操作测试用）
// 启动：php -S 127.0.0.1:9800 -t test/
// 客户端连接：http://127.0.0.1:9800/server.php
// （端口由 interop.sh 的 PHP_PORT 环境变量控制，默认 9800，属 interop job 9800-9819 区段）
//
// 方法与 lua-yar 互操作测试服务端（test/interop_lua_server.lua）对齐：
//   add(a, b)   → a + b
//   sub(a, b)   → a - b
//   upper(s)    → strtoupper(s)
//   greet(name) → "hello, " . name

class API {
    public function add($a, $b) {
        return $a + $b;
    }
    public function sub($a, $b) {
        return $a - $b;
    }
    public function upper($s) {
        return strtoupper($s);
    }
    public function greet($name) {
        return "hello, " . $name;
    }
}

$service = new Yar_Server(new API());
$service->handle();
