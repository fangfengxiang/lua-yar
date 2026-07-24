#!/bin/bash
# test/interop.sh
# 互操作测试编排：lua-yar ↔ PHP Yar 双向端到端（HTTP + TCP）
#
# HTTP 场景：
#   1. Lua 客户端 → PHP Yar 服务端（JSON + Msgpack）
#   2. PHP 客户端 → Lua Yar 服务端（JSON + Msgpack）
# TCP 场景：
#   3. Lua 客户端 → Lua Yar TCP 服务端（JSON + Msgpack + persistent）
#   4. PHP 客户端 → Lua Yar TCP 服务端（JSON + Msgpack）
#
# 运行：bash test/interop.sh
#
# 环境要求：
#   - Lua 5.1+ + luasocket（TCP 场景必需，Lua→Lua TCP 不依赖 PHP）
#   - PHP + yar 扩展 + msgpack 扩展（HTTP 场景和 PHP→Lua TCP 场景必需）

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PHP_PORT="${PHP_PORT:-9800}"
LUA_HTTP_PORT="${LUA_HTTP_PORT:-9801}"
LUA_TCP_PORT="${LUA_TCP_PORT:-9802}"

# 端口分配见 test/PORTS.md（interop job: 9800=PHP, 9801=Lua HTTP, 9802=Lua TCP）

cd "$PROJECT_ROOT"

# 加载共享测试函数（端口检测、进程清理）
source "$SCRIPT_DIR/test_helpers.sh"

# 检查依赖
echo "=== Yar-Lua ↔ PHP Interoperability Tests (HTTP + TCP) ==="
echo ""

if ! command -v lua &>/dev/null; then
    echo "[SKIP] lua not found, skipping interop tests"
    exit 0
fi
echo "[deps] Lua: OK"

HAS_PHP_YAR=false
if command -v php &>/dev/null && php -m 2>/dev/null | grep -qi "^yar$"; then
    HAS_PHP_YAR=true
    echo "[deps] PHP + yar extension: OK"
else
    echo "[deps] PHP + yar extension: NOT FOUND (HTTP interop + PHP→Lua TCP will be skipped)"
fi
echo ""

# 结果汇总
RESULTS=()
ALL_PASS=true

# ── 场景 1：Lua 客户端 → PHP 服务端（HTTP）─────────────────────

if [ "$HAS_PHP_YAR" = true ]; then
    echo "--- Scenario 1: Lua client → PHP server (HTTP) ---"

    echo "  [setup] Starting PHP server on port $PHP_PORT..."
    wait_port_free "$PHP_PORT"
    php -S 127.0.0.1:$PHP_PORT -t test/ > /dev/null 2>&1 &
    PHP_PID=$!
    trap "kill $PHP_PID 2>/dev/null || true" EXIT

    sleep 1
    if ! curl -s "http://127.0.0.1:$PHP_PORT/server.php" -o /dev/null 2>/dev/null; then
        echo "  [FAIL] PHP server failed to start"
        RESULTS+=("Lua → PHP (HTTP): FAIL")
        ALL_PASS=false
    else
        echo "  [setup] PHP server is ready"
        set +e
        lua test/interop_lua_to_php.lua
        LUA_TO_PHP_RESULT=$?
        set -e

        if [ $LUA_TO_PHP_RESULT -eq 0 ]; then
            RESULTS+=("Lua → PHP (HTTP): PASS")
        else
            RESULTS+=("Lua → PHP (HTTP): FAIL")
            ALL_PASS=false
        fi
    fi

    kill $PHP_PID 2>/dev/null || true
    wait $PHP_PID 2>/dev/null || true
    trap - EXIT
    echo ""
else
    echo "--- Scenario 1: Lua client → PHP server (HTTP) [SKIPPED: no PHP yar] ---"
    echo ""
fi

# ── 场景 2：PHP 客户端 → Lua 服务端（HTTP）─────────────────────

if [ "$HAS_PHP_YAR" = true ]; then
    echo "--- Scenario 2: PHP client → Lua server (HTTP) ---"

    echo "  [setup] Starting Lua HTTP server on port $LUA_HTTP_PORT..."
    wait_port_free "$LUA_HTTP_PORT"
    lua test/interop_lua_server.lua "$LUA_HTTP_PORT" > /dev/null 2>&1 &
    LUA_HTTP_PID=$!
    trap "kill $LUA_HTTP_PID 2>/dev/null || true" EXIT

    sleep 1
    if ! curl -s "http://127.0.0.1:$LUA_HTTP_PORT/" -o /dev/null 2>/dev/null; then
        echo "  [FAIL] Lua HTTP server failed to start"
        RESULTS+=("PHP → Lua (HTTP): FAIL")
        ALL_PASS=false
    else
        echo "  [setup] Lua HTTP server is ready"
        set +e
        php test/interop_php_to_lua.php
        PHP_TO_LUA_RESULT=$?
        set -e

        if [ $PHP_TO_LUA_RESULT -eq 0 ]; then
            RESULTS+=("PHP → Lua (HTTP): PASS")
        else
            RESULTS+=("PHP → Lua (HTTP): FAIL")
            ALL_PASS=false
        fi
    fi

    kill $LUA_HTTP_PID 2>/dev/null || true
    wait $LUA_HTTP_PID 2>/dev/null || true
    trap - EXIT
    echo ""
else
    echo "--- Scenario 2: PHP client → Lua server (HTTP) [SKIPPED: no PHP yar] ---"
    echo ""
fi

# ── 场景 3：Lua 客户端 → Lua TCP 服务端 ───────────────────────
# 不依赖 PHP，纯 Lua TCP transport 互操作性验证

echo "--- Scenario 3: Lua client → Lua TCP server ---"

echo "  [setup] Starting Lua TCP server on port $LUA_TCP_PORT..."
wait_port_free "$LUA_TCP_PORT"
lua test/interop_lua_tcp_server.lua "$LUA_TCP_PORT" > /dev/null 2>&1 &
LUA_TCP_PID=$!
trap "kill $LUA_TCP_PID 2>/dev/null || true" EXIT

sleep 1
echo "  [setup] Lua TCP server is ready"
set +e
lua test/interop_lua_to_lua_tcp.lua
LUA_TO_LUA_TCP_RESULT=$?
set -e

if [ $LUA_TO_LUA_TCP_RESULT -eq 0 ]; then
    RESULTS+=("Lua → Lua TCP: PASS")
else
    RESULTS+=("Lua → Lua TCP: FAIL")
    ALL_PASS=false
fi

kill $LUA_TCP_PID 2>/dev/null || true
wait $LUA_TCP_PID 2>/dev/null || true
trap - EXIT
echo ""

# ── 场景 4：PHP 客户端 → Lua TCP 服务端 ───────────────────────

if [ "$HAS_PHP_YAR" = true ]; then
    echo "--- Scenario 4: PHP client → Lua TCP server ---"

    echo "  [setup] Starting Lua TCP server on port $LUA_TCP_PORT..."
    wait_port_free "$LUA_TCP_PORT"
    lua test/interop_lua_tcp_server.lua "$LUA_TCP_PORT" > /dev/null 2>&1 &
    LUA_TCP_PID=$!
    trap "kill $LUA_TCP_PID 2>/dev/null || true" EXIT

    sleep 1
    echo "  [setup] Lua TCP server is ready"
    set +e
    php test/interop_php_to_lua_tcp.php
    PHP_TO_LUA_TCP_RESULT=$?
    set -e

    if [ $PHP_TO_LUA_TCP_RESULT -eq 0 ]; then
        RESULTS+=("PHP → Lua TCP: PASS")
    else
        RESULTS+=("PHP → Lua TCP: FAIL")
        ALL_PASS=false
    fi

    kill $LUA_TCP_PID 2>/dev/null || true
    wait $LUA_TCP_PID 2>/dev/null || true
    trap - EXIT
    echo ""
else
    echo "--- Scenario 4: PHP client → Lua TCP server [SKIPPED: no PHP yar] ---"
    echo ""
fi

# ── 汇总 ─────────────────────────────────────────────────────

echo "=== Summary ==="
for r in "${RESULTS[@]}"; do
    echo "  $r"
done
echo ""

if [ "$ALL_PASS" = false ]; then
    echo "=== Interop tests FAILED ==="
    exit 1
fi

echo "=== Interop tests PASSED ==="
