#!/bin/bash
# test/e2e/lua_to_lua_http.sh
# 场景：Lua yar client → Lua server（HTTP），JSON + Msgpack
# 断言：add(a,b) = a+b
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/test/test_helpers.sh"

LUA_HTTP_PORT="${LUA_HTTP_PORT:-9801}"

cd "$PROJECT_ROOT"
echo "--- Scenario: Lua → Lua (HTTP) ---"

# 启动 Lua HTTP server
wait_port_free "$LUA_HTTP_PORT"
lua test/e2e/lua_http_server.lua "$LUA_HTTP_PORT" > /dev/null 2>&1 &
SERVER_PID=$!
trap "kill $SERVER_PID 2>/dev/null || true" EXIT
sleep 1

# 健康检查
if ! curl -s "http://127.0.0.1:$LUA_HTTP_PORT/" -o /dev/null 2>/dev/null; then
    echo "  [FAIL] Lua HTTP server failed to start"
    exit 1
fi
echo "  [setup] Lua HTTP server ready on port $LUA_HTTP_PORT"

URL="http://127.0.0.1:$LUA_HTTP_PORT/"
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
    echo "  [PASS] Lua → Lua (HTTP)"
    exit 0
else
    echo "  [FAIL] Lua → Lua (HTTP)"
    exit 1
fi
