#!/bin/bash
# test/e2e/php_to_lua_tcp.sh
# 场景：PHP yar client → Lua server（TCP），JSON + Msgpack
# 断言：add(a,b) = a+b
# 依赖：PHP + yar 扩展 + msgpack 扩展
# 注意：PHP Yar 的 tcp:// transport 支持取决于 yar 扩展编译选项
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/test/test_helpers.sh"

LUA_TCP_PORT="${LUA_TCP_PORT:-9802}"

cd "$PROJECT_ROOT"
echo "--- Scenario: PHP → Lua (TCP) ---"

# 启动 Lua TCP server
wait_port_free "$LUA_TCP_PORT"
lua test/e2e/lua_tcp_server.lua "$LUA_TCP_PORT" > /dev/null 2>&1 &
SERVER_PID=$!
trap "kill $SERVER_PID 2>/dev/null || true" EXIT
sleep 1

echo "  [setup] Lua TCP server ready on port $LUA_TCP_PORT"

URL="tcp://127.0.0.1:$LUA_TCP_PORT"
FAIL=0

# JSON
echo "  [test] JSON packager..."
set +e
php test/e2e/php_client.php "$URL" json
RC=$?
set -e
# PHP Yar tcp:// 不支持时 exit 0 + SKIP 提示（php_client.php 内部 catch 输出 FAIL）
[ $RC -ne 0 ] && FAIL=1

# Msgpack
echo "  [test] Msgpack packager..."
set +e
php test/e2e/php_client.php "$URL" msgpack
RC=$?
set -e
[ $RC -ne 0 ] && FAIL=1

if [ $FAIL -eq 0 ]; then
    echo "  [PASS] PHP → Lua (TCP)"
    exit 0
else
    echo "  [FAIL] PHP → Lua (TCP)"
    exit 1
fi
