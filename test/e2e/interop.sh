#!/bin/bash
# test/e2e/interop.sh
# E2E 测试 runner：串联跑所有场景，汇总结果
#
# 场景列表：
#   Lua 自操作：
#     1. lua_to_lua_http.sh    — Lua client → Lua server (HTTP), JSON + Msgpack
#     2. lua_to_lua_tcp.sh     — Lua client → Lua server (TCP),  JSON + Msgpack
#   PHP-Lua 互通：
#     3. php_to_lua_http.sh    — PHP client → Lua server (HTTP), JSON + Msgpack
#     4. php_to_lua_tcp.sh     — PHP client → Lua server (TCP),  JSON + Msgpack
#     5. lua_to_php_http.sh    — Lua client → PHP server (HTTP), JSON + Msgpack
#
# 用法：bash test/e2e/interop.sh
# CI/CD：先跑 check_env.sh 评估环境，再跑本脚本

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================"
echo "  Yar-Lua E2E Test Suite"
echo "============================================"
echo ""

# 环境检查
echo "[step 0] Environment check..."
bash "$SCRIPT_DIR/check_env.sh"
ENV_RC=$?
echo ""

# 根据环境决定跑哪些场景
HAS_PHP_YAR=false
if command -v php &>/dev/null && php -m 2>/dev/null | grep -qi "^yar$"; then
    HAS_PHP_YAR=true
fi

SCENARIOS=()
SCENARIOS+=("lua_to_lua_http.sh|Lua → Lua (HTTP)")
SCENARIOS+=("lua_to_lua_tcp.sh|Lua → Lua (TCP)")

if [ "$HAS_PHP_YAR" = true ]; then
    SCENARIOS+=("php_to_lua_http.sh|PHP → Lua (HTTP)")
    SCENARIOS+=("php_to_lua_tcp.sh|PHP → Lua (TCP)")
    SCENARIOS+=("lua_to_php_http.sh|Lua → PHP (HTTP)")
else
    echo "[skip] PHP yar not available — skipping 3 interop scenarios"
    echo ""
fi

# 跑场景
PASS=0
FAIL=0
FAILED_SCENARIOS=()

for entry in "${SCENARIOS[@]}"; do
    script=$(echo "$entry" | cut -d'|' -f1)
    label=$(echo "$entry" | cut -d'|' -f2)

    echo "[$((PASS + FAIL + 1))/${#SCENARIOS[@]}] $label"
    set +e
    bash "$SCRIPT_DIR/$script"
    RC=$?
    set -e

    if [ $RC -eq 0 ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_SCENARIOS+=("$label")
    fi
    echo ""
done

# 汇总
echo "============================================"
echo "  E2E Test Summary"
echo "============================================"
echo "  Scenarios: $((PASS + FAIL)) total, $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
    echo "  Failed:"
    for s in "${FAILED_SCENARIOS[@]}"; do
        echo "    - $s"
    done
fi
echo ""

if [ $FAIL -gt 0 ]; then
    echo "=== E2E tests FAILED ==="
    exit 1
fi

echo "=== E2E tests PASSED ==="
