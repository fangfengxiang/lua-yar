<?php
// test/e2e/php_server.php
// E2E PHP Yar 服务端：提供 add(a,b) 方法
// 启动：php -S 127.0.0.1:<port> -t test/e2e/
// 客户端连接：http://127.0.0.1:<port>/php_server.php

class API {
    public function add($a, $b) {
        return $a + $b;
    }
}

$service = new Yar_Server(new API());
$service->handle();
