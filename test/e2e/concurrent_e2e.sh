#!/bin/bash
# test/e2e/concurrent_e2e.sh
# 并发端到端测试编排：PHP 客户端并发 → Lua Yar 原生服务端（HTTP + TCP）
#
# 测试场景：
#   场景 1: PHP 3 并发 → Lua 原生 HTTP 服务端（顺序处理，端口 9803）
#   场景 2: PHP 3 并发 → Lua 原生 TCP 服务端（顺序处理，端口 9804）
#
# 验证点：
#   - 原生服务端顺序处理：3 并发请求不丢、不串数据
#   - requestId 数据完整性：每个响应与请求匹配
#   - JSON + Msgpack 两个 packager 都覆盖
#
# 运行：bash test/e2e/concurrent_e2e.sh [scenario]
#   scenario 可选值：
#     all          — 运行全部（默认，场景 1+2）
#     native-http  — 仅场景 1（PHP 3 并发 → Lua 原生 HTTP）
#     native-tcp   — 仅场景 2（PHP 3 并发 → Lua 原生 TCP）
#
# 注意：OpenResty 并发测试已迁移至 test/openresty/concurrent_openresty.sh
#
# 环境要求：
#   - Lua 5.1+ + luasocket（原生服务端）
#   - PHP + yar + msgpack + pcntl 扩展（PHP 并发客户端）

set -e

SCENARIO="${1:-all}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$PROJECT_ROOT"

echo "=== Yar-Lua Concurrent E2E Tests (PHP → Lua, HTTP + TCP) ==="
echo ""

# 检查依赖
if ! command -v lua &>/dev/null; then
    echo "[SKIP] lua not found"
    exit 0
fi
echo "[deps] Lua: OK"

HAS_PHP_PCNTL=false
HAS_PHP_YAR=false
if command -v php &>/dev/null; then
    if php -m 2>/dev/null | grep -qi "^pcntl$"; then
        HAS_PHP_PCNTL=true
    fi
    if php -m 2>/dev/null | grep -qi "^yar$"; then
        HAS_PHP_YAR=true
    fi
fi

if [ "$HAS_PHP_PCNTL" = true ] && [ "$HAS_PHP_YAR" = true ]; then
    echo "[deps] PHP + yar + pcntl: OK"
else
    echo "[deps] PHP + yar + pcntl: NOT FOUND (all concurrent tests will be skipped)"
    echo ""
    echo "=== Concurrent E2E tests SKIPPED (no PHP yar/pcntl) ==="
    exit 0
fi
echo ""

# 结果汇总
RESULTS=()
ALL_PASS=true

LUA_HTTP_PORT="${CONCURRENT_LUA_HTTP_PORT:-9803}"
LUA_TCP_PORT="${CONCURRENT_LUA_TCP_PORT:-9804}"

# 端口分配见 test/PORTS.md（interop job: 9803=并发Lua HTTP, 9804=并发Lua TCP）

# 加载共享测试函数（端口检测、进程清理）
source "$PROJECT_ROOT/test/test_helpers.sh"

# ── 场景 1：PHP 3 并发 → Lua 原生 HTTP 服务端 ─────────────────

if [ "$SCENARIO" = "all" ] || [ "$SCENARIO" = "native-http" ]; then

echo "--- Scenario 1: PHP 3 concurrent → Lua native HTTP (sequential) ---"

echo "  [setup] Starting Lua HTTP server on port $LUA_HTTP_PORT..."
wait_port_free "$LUA_HTTP_PORT"
lua "$SCRIPT_DIR/lua_http_server.lua" "$LUA_HTTP_PORT" > /dev/null 2>&1 &
LUA_HTTP_PID=$!
trap "kill $LUA_HTTP_PID 2>/dev/null || true" EXIT

sleep 1
if ! curl -s "http://127.0.0.1:$LUA_HTTP_PORT/" -o /dev/null 2>/dev/null; then
    echo "  [FAIL] Lua HTTP server failed to start"
    RESULTS+=("PHP → Lua HTTP (3 concurrent): FAIL")
    ALL_PASS=false
else
    echo "  [setup] Lua HTTP server is ready"
    set +e
    php "$SCRIPT_DIR/concurrent_php_to_lua_http.php"
    HTTP_RESULT=$?
    set -e

    if [ $HTTP_RESULT -eq 0 ]; then
        RESULTS+=("PHP → Lua HTTP (3 concurrent): PASS")
    else
        RESULTS+=("PHP → Lua HTTP (3 concurrent): FAIL")
        ALL_PASS=false
    fi
fi

kill $LUA_HTTP_PID 2>/dev/null || true
wait $LUA_HTTP_PID 2>/dev/null || true
trap - EXIT
echo ""

fi  # end scenario 1

# ── 场景 2：PHP 3 并发 → Lua 原生 TCP 服务端 ──────────────────

if [ "$SCENARIO" = "all" ] || [ "$SCENARIO" = "native-tcp" ]; then

echo "--- Scenario 2: PHP 3 concurrent → Lua native TCP (sequential) ---"

echo "  [setup] Starting Lua TCP server on port $LUA_TCP_PORT..."
wait_port_free "$LUA_TCP_PORT"
lua "$SCRIPT_DIR/lua_tcp_server.lua" "$LUA_TCP_PORT" > /dev/null 2>&1 &
LUA_TCP_PID=$!
trap "kill $LUA_TCP_PID 2>/dev/null || true" EXIT

sleep 1
echo "  [setup] Lua TCP server is ready"
set +e
php "$SCRIPT_DIR/concurrent_php_to_lua_tcp.php"
TCP_RESULT=$?
set -e

if [ $TCP_RESULT -eq 0 ]; then
    RESULTS+=("PHP → Lua TCP (3 concurrent): PASS")
else
    RESULTS+=("PHP → Lua TCP (3 concurrent): FAIL")
    ALL_PASS=false
fi

kill $LUA_TCP_PID 2>/dev/null || true
wait $LUA_TCP_PID 2>/dev/null || true
trap - EXIT
echo ""

fi  # end scenario 2

# ── 汇总 ─────────────────────────────────────────────────────

echo "=== Summary ==="
for r in "${RESULTS[@]}"; do
    echo "  $r"
done
echo ""

if [ "$ALL_PASS" = false ]; then
    echo "=== Concurrent E2E tests FAILED ==="
    exit 1
fi

echo "=== Concurrent E2E tests PASSED ==="
