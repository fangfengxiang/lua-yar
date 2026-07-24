#!/bin/bash
# test/concurrent_e2e.sh
# 并发端到端测试总编排：PHP 客户端并发 → Lua Yar 服务端（原生 + OpenResty，HTTP + TCP）
#
# 测试场景：
#   场景 1: PHP 3 并发 → Lua 原生 HTTP 服务端（顺序处理，端口 9803）
#   场景 2: PHP 3 并发 → Lua 原生 TCP 服务端（顺序处理，端口 9804）
#   场景 3: PHP 50 并发 → OpenResty HTTP 服务端（2 workers 协程并发，端口 9805）
#   场景 4: PHP 50 并发 → OpenResty TCP 服务端（2 workers 协程并发，端口 9806）
#
# 验证点：
#   - 原生服务端顺序处理：3 并发请求不丢、不串数据
#   - OpenResty 服务端协程并发：50 并发请求全部正确响应
#   - requestId 数据完整性：每个响应与请求匹配
#   - 日志协程异常检测：nginx error.log 无 status=error 记录
#   - 多 worker 负载分担：至少 2 个 worker_id 参与处理
#   - JSON + Msgpack 两个 packager 都覆盖
#
# 运行：bash test/concurrent_e2e.sh
#
# 环境要求：
#   - Lua 5.1+ + luasocket（原生服务端）
#   - PHP + yar + msgpack + pcntl 扩展（PHP 并发客户端）
#   - OpenResty（含 stream-lua-module）（OpenResty 服务端）

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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
# 场景 3+4 委托给 concurrent_openresty.sh，使用 9805/9806（通过环境变量传递）

# 加载共享测试函数（端口检测、进程清理）
source "$SCRIPT_DIR/test_helpers.sh"

# 为 concurrent_openresty.sh 设置端口（interop job 范围）
export CONCURRENT_HTTP_PORT="${CONCURRENT_HTTP_PORT:-9805}"
export CONCURRENT_TCP_PORT="${CONCURRENT_TCP_PORT:-9806}"

# ── 场景 1：PHP 3 并发 → Lua 原生 HTTP 服务端 ─────────────────

echo "--- Scenario 1: PHP 3 concurrent → Lua native HTTP (sequential) ---"

echo "  [setup] Starting Lua HTTP server on port $LUA_HTTP_PORT..."
wait_port_free "$LUA_HTTP_PORT"
lua test/interop_lua_server.lua "$LUA_HTTP_PORT" > /dev/null 2>&1 &
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
    php test/concurrent_php_to_lua_http.php
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

# ── 场景 2：PHP 3 并发 → Lua 原生 TCP 服务端 ──────────────────

echo "--- Scenario 2: PHP 3 concurrent → Lua native TCP (sequential) ---"

echo "  [setup] Starting Lua TCP server on port $LUA_TCP_PORT..."
wait_port_free "$LUA_TCP_PORT"
lua test/interop_lua_tcp_server.lua "$LUA_TCP_PORT" > /dev/null 2>&1 &
LUA_TCP_PID=$!
trap "kill $LUA_TCP_PID 2>/dev/null || true" EXIT

sleep 1
echo "  [setup] Lua TCP server is ready"
set +e
php test/concurrent_php_to_lua_tcp.php
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

# ── 场景 3+4：PHP 50 并发 → OpenResty (HTTP + TCP) ────────────
# 委托给 concurrent_openresty.sh（启动 nginx 2 workers + 运行 PHP 50 并发测试）

echo "--- Scenario 3+4: PHP 50 concurrent → OpenResty (HTTP + TCP, 2 workers) ---"
echo ""

if bash test/concurrent_openresty.sh; then
    RESULTS+=("PHP → OpenResty HTTP (50 concurrent): PASS")
    RESULTS+=("PHP → OpenResty TCP (50 concurrent): PASS")
else
    RESULTS+=("PHP → OpenResty HTTP (50 concurrent): FAIL (or SKIPPED)")
    RESULTS+=("PHP → OpenResty TCP (50 concurrent): FAIL (or SKIPPED)")
    ALL_PASS=false
fi
echo ""

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
