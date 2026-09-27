#!/bin/bash
# test/e2e/check_env.sh
# E2E 测试环境检查：在跑互通场景前，评估环境是否满足
#
# 检查项：
#   1. Lua 可用 + 版本
#   2. luasocket 可用（TCP 场景必需）
#   3. PHP 可用 + 版本
#   4. PHP yar 扩展（互通场景必需）
#   5. PHP msgpack 扩展（Msgpack packager 必需）
#   6. 端口可用性（9800/9801/9802）
#
# 用法：bash test/e2e/check_env.sh
# 退出码：0=环境满足全部场景，1=有缺失（仅告警不阻断 Lua 自操作场景）

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/test/test_helpers.sh"

cd "$PROJECT_ROOT"

echo "=== E2E Environment Check ==="
echo ""

ERRORS=0
WARNINGS=0

# ── 1. Lua ──────────────────────────────────────────────────
if command -v lua &>/dev/null; then
    LUA_VER=$(lua -v 2>&1 | head -1)
    echo "  [OK] Lua: $LUA_VER"
else
    echo "  [ERROR] Lua not found"
    ERRORS=$((ERRORS + 1))
fi

# ── 2. luasocket（TCP 场景必需）──────────────────────────────
if command -v lua &>/dev/null; then
    LUA_PATH="src/?.lua;src/?/init.lua;;" lua -e 'require("socket")' 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "  [OK] luasocket: available"
    else
        echo "  [WARN] luasocket not found (TCP scenarios will be skipped)"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# ── 3. PHP ──────────────────────────────────────────────────
HAS_PHP=false
if command -v php &>/dev/null; then
    PHP_VER=$(php -v 2>&1 | head -1)
    echo "  [OK] PHP: $PHP_VER"
    HAS_PHP=true
else
    echo "  [WARN] PHP not found (interop scenarios will be skipped)"
    WARNINGS=$((WARNINGS + 1))
fi

# ── 4. PHP yar 扩展 ─────────────────────────────────────────
HAS_PHP_YAR=false
if [ "$HAS_PHP" = true ]; then
    if php -m 2>/dev/null | grep -qi "^yar$"; then
        echo "  [OK] PHP yar extension: loaded"
        HAS_PHP_YAR=true
    else
        echo "  [WARN] PHP yar extension not loaded (interop scenarios will be skipped)"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# ── 5. PHP msgpack 扩展 ─────────────────────────────────────
HAS_PHP_MSGPACK=false
if [ "$HAS_PHP_YAR" = true ]; then
    if php -m 2>/dev/null | grep -qi "^msgpack$"; then
        echo "  [OK] PHP msgpack extension: loaded"
        HAS_PHP_MSGPACK=true
    else
        echo "  [WARN] PHP msgpack extension not loaded (Msgpack interop will be skipped)"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# ── 6. 端口可用性 ───────────────────────────────────────────
for port in 9800 9801 9802; do
    if is_port_free "$port"; then
        echo "  [OK] Port $port: free"
    else
        echo "  [WARN] Port $port: occupied (will wait up to 5s during test)"
        WARNINGS=$((WARNINGS + 1))
    fi
done

# ── 汇总 ────────────────────────────────────────────────────
echo ""
echo "=== Environment Summary ==="
echo "  Lua self-interop (HTTP + TCP):   $([ $ERRORS -eq 0 ] && echo 'READY' || echo 'BLOCKED')"
echo "  PHP → Lua interop (HTTP + TCP):  $([ "$HAS_PHP_YAR" = true ] && echo 'READY' || echo 'SKIP')"
echo "  Lua → PHP interop (HTTP):       $([ "$HAS_PHP_YAR" = true ] && echo 'READY' || echo 'SKIP')"
echo ""

if [ $ERRORS -gt 0 ]; then
    echo "=== Environment check: BLOCKED ($ERRORS errors) ==="
    exit 1
fi

echo "=== Environment check: OK ($WARNINGS warnings) ==="
exit 0
