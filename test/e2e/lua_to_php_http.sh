#!/bin/bash
# test/e2e/lua_to_php_http.sh
# 场景：Lua yar client → PHP server（HTTP），JSON + Msgpack
# 断言：add(a,b) = a+b
# 依赖：PHP + yar 扩展 + msgpack 扩展
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/test/test_helpers.sh"

PHP_PORT="${PHP_PORT:-9800}"

cd "$PROJECT_ROOT"
echo "--- Scenario: Lua → PHP (HTTP) ---"

# 启动 PHP server
wait_port_free "$PHP_PORT"
php -S 127.0.0.1:$PHP_PORT -t test/e2e/ > /dev/null 2>&1 &
SERVER_PID=$!
trap "kill $SERVER_PID 2>/dev/null || true" EXIT
sleep 1

# 健康检查
if ! curl -s "http://127.0.0.1:$PHP_PORT/php_server.php" -o /dev/null 2>/dev/null; then
    echo "  [FAIL] PHP server failed to start"
    exit 1
fi
echo "  [setup] PHP server ready on port $PHP_PORT"

URL="http://127.0.0.1:$PHP_PORT/php_server.php"
FAIL=0

# JSON
echo "  [test] JSON packager..."
set +e
lua test/e2e/lua_client.lua "$URL" json
RC=$?
set -e
[ $RC -ne 0 ] && FAIL=1

# Msgpack
echo "  [test] Msgpack packager..."
set +e
lua test/e2e/lua_client.lua "$URL" msgpack
RC=$?
set -e
[ $RC -ne 0 ] && FAIL=1

if [ $FAIL -eq 0 ]; then
    echo "  [PASS] Lua → PHP (HTTP)"
    exit 0
else
    echo "  [FAIL] Lua → PHP (HTTP)"
    exit 1
fi
