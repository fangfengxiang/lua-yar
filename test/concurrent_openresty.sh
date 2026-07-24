#!/bin/bash
# test/concurrent_openresty.sh
# OpenResty 并发端到端测试编排：启动 nginx (2 workers, HTTP+TCP) + 运行 PHP 50 并发测试 + 停止 nginx
#
# 测试场景：
#   - HTTP: PHP 50 并发 → OpenResty HTTP 服务端 (2 workers, content_by_lua 协程并发)
#   - TCP:  PHP 50 并发 → OpenResty TCP 服务端  (2 workers, stream content_by_lua 协程并发)
#   - 验证 requestId 数据完整性 + 日志协程异常检测
#
# 运行：bash test/concurrent_openresty.sh
#
# 环境要求：
#   - OpenResty（含 stream-lua-module）
#   - PHP + yar 扩展 + msgpack 扩展 + pcntl 扩展

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NGINX_PREFIX="/tmp/yar_concurrent_nginx"
HTTP_PORT="${CONCURRENT_HTTP_PORT:-9707}"
TCP_PORT="${CONCURRENT_TCP_PORT:-9708}"

# 端口分配见 test/PORTS.md（openresty job: 9707=并发HTTP, 9708=并发TCP）
# interop job 通过环境变量覆盖为 9805/9806

cd "$PROJECT_ROOT"

# 加载共享测试函数（端口清理等）
source "$SCRIPT_DIR/test_helpers.sh"

# trap：脚本退出时确保 nginx 停止（即使中途失败）
cleanup() {
    cleanup_nginx "$NGINX_PREFIX"
}
trap cleanup EXIT

# 检查 openresty 可用
OPENRESTY="${OPENRESTY:-openresty}"
if [ -x /usr/local/openresty/bin/openresty ]; then
    OPENRESTY="/usr/local/openresty/bin/openresty"
elif command -v openresty &>/dev/null; then
    OPENRESTY="openresty"
else
    echo "[SKIP] openresty not found, skipping OpenResty concurrent tests"
    exit 0
fi

echo "=== OpenResty Concurrent E2E Tests (2 workers, HTTP + TCP) ==="
echo ""

# 检查 PHP + pcntl
HAS_PHP_PCNTL=false
if command -v php &>/dev/null && php -m 2>/dev/null | grep -qi "^pcntl$"; then
    HAS_PHP_PCNTL=true
    echo "[deps] PHP + pcntl: OK"
else
    echo "[deps] PHP + pcntl: NOT FOUND (OpenResty concurrent tests will be skipped)"
fi

# 检查 PHP yar 扩展
HAS_PHP_YAR=false
if [ "$HAS_PHP_PCNTL" = true ] && php -m 2>/dev/null | grep -qi "^yar$"; then
    HAS_PHP_YAR=true
    echo "[deps] PHP + yar extension: OK"
else
    echo "[deps] PHP + yar extension: NOT FOUND"
fi
echo ""

# 结果汇总
RESULTS=()
ALL_PASS=true

# 清理本脚本旧实例（只清理自己的 prefix，不影响其他 nginx 实例）
cleanup_nginx "$NGINX_PREFIX"
sleep 0.5
rm -rf "$NGINX_PREFIX"
mkdir -p "$NGINX_PREFIX/logs"

# 端口占用检测（不杀别人的进程，等待 5 秒）
wait_port_free "$HTTP_PORT"
wait_port_free "$TCP_PORT"

# 生成 nginx.conf（2 workers, HTTP + stream TCP）
cat > "$NGINX_PREFIX/nginx.conf" << 'NGINX_EOF'
worker_processes  2;
error_log  NGINX_PREFIX/logs/error.log  info;
pid        NGINX_PREFIX/nginx.pid;

events {
    worker_connections  1024;
}

http {
    lua_package_path "PROJECT_ROOT/src/?.lua;PROJECT_ROOT/src/?/init.lua;PROJECT_ROOT/test/?.lua;;";

    init_by_lua_block {
        -- 预加载 server handler 模块（进程级 Server 实例）
        require("test.nginx_concurrent_server")
    }

    server {
        listen 127.0.0.1:HTTP_PORT_PLACEHOLDER;
        server_name localhost;

        location /api {
            content_by_lua_block {
                require("test.nginx_concurrent_server").serve()
            }
        }

        location /health {
            content_by_lua_block {
                ngx.print("ok")
            }
        }
    }
}

stream {
    lua_package_path "PROJECT_ROOT/src/?.lua;PROJECT_ROOT/src/?/init.lua;PROJECT_ROOT/test/?.lua;;";

    init_by_lua_block {
        -- 预加载 stream server handler 模块
        require("test.nginx_stream_server")
    }

    server {
        listen 127.0.0.1:TCP_PORT_PLACEHOLDER;
        content_by_lua_block {
            require("test.nginx_stream_server").serve()
        }
    }
}
NGINX_EOF

# 替换占位符（路径 + 端口）
sed -i.bak "s|NGINX_PREFIX|$NGINX_PREFIX|g" "$NGINX_PREFIX/nginx.conf"
sed -i.bak "s|PROJECT_ROOT|$PROJECT_ROOT|g" "$NGINX_PREFIX/nginx.conf"
sed -i.bak "s|HTTP_PORT_PLACEHOLDER|$HTTP_PORT|g" "$NGINX_PREFIX/nginx.conf"
sed -i.bak "s|TCP_PORT_PLACEHOLDER|$TCP_PORT|g" "$NGINX_PREFIX/nginx.conf"
rm -f "$NGINX_PREFIX/nginx.conf.bak"

NGINX_ERROR_LOG="$NGINX_PREFIX/logs/error.log"

# 启动 nginx
echo "[setup] Starting OpenResty nginx (2 workers, HTTP:$HTTP_PORT + TCP:$TCP_PORT)..."
$OPENRESTY -p "$NGINX_PREFIX" -c "$NGINX_PREFIX/nginx.conf" 2>&1 || {
    echo "  [FAIL] nginx failed to start"
    cat "$NGINX_ERROR_LOG" 2>/dev/null | tail -20
    exit 1
}
sleep 1

# 健康检查（HTTP）
echo "[setup] Health check..."
if curl -s "http://127.0.0.1:$HTTP_PORT/health" 2>/dev/null | grep -q "ok"; then
    echo "  HTTP server is healthy"
else
    echo "  [FAIL] nginx HTTP health check failed"
    cat "$NGINX_ERROR_LOG" 2>/dev/null | tail -20
    $OPENRESTY -p "$NGINX_PREFIX" -s stop 2>/dev/null || true
    exit 1
fi

# ── 场景 1：PHP 50 并发 → OpenResty HTTP ──────────────────────

if [ "$HAS_PHP_YAR" = true ]; then
    echo ""
    echo "--- Scenario 1: PHP 50 concurrent → OpenResty HTTP (2 workers) ---"

    # 清空日志以便干净验证
    > "$NGINX_ERROR_LOG"

    set +e
    php "$SCRIPT_DIR/concurrent_php_to_openresty_http.php" "$NGINX_ERROR_LOG"
    HTTP_RESULT=$?
    set -e

    if [ $HTTP_RESULT -eq 0 ]; then
        RESULTS+=("PHP → OpenResty HTTP (50 concurrent): PASS")
    else
        RESULTS+=("PHP → OpenResty HTTP (50 concurrent): FAIL")
        ALL_PASS=false
    fi
else
    echo "--- Scenario 1: PHP → OpenResty HTTP [SKIPPED: no PHP yar/pcntl] ---"
fi

# ── 场景 2：PHP 50 并发 → OpenResty TCP ───────────────────────

if [ "$HAS_PHP_YAR" = true ]; then
    echo ""
    echo "--- Scenario 2: PHP 50 concurrent → OpenResty TCP (2 workers) ---"

    # 清空日志
    > "$NGINX_ERROR_LOG"

    set +e
    php "$SCRIPT_DIR/concurrent_php_to_openresty_tcp.php" "$NGINX_ERROR_LOG"
    TCP_RESULT=$?
    set -e

    if [ $TCP_RESULT -eq 0 ]; then
        RESULTS+=("PHP → OpenResty TCP (50 concurrent): PASS")
    else
        RESULTS+=("PHP → OpenResty TCP (50 concurrent): FAIL")
        ALL_PASS=false
    fi
else
    echo "--- Scenario 2: PHP → OpenResty TCP [SKIPPED: no PHP yar/pcntl] ---"
fi

# 停止 nginx
echo ""
echo "[teardown] Stopping OpenResty nginx..."
$OPENRESTY -p "$NGINX_PREFIX" -s stop 2>/dev/null || true
sleep 1

# 汇总
echo ""
echo "=== Summary ==="
for r in "${RESULTS[@]}"; do
    echo "  $r"
done
echo ""

if [ "$ALL_PASS" = false ]; then
    echo "=== OpenResty concurrent tests FAILED ==="
    exit 1
fi

echo "=== OpenResty concurrent tests PASSED ==="
