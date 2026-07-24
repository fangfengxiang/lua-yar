#!/bin/bash
# test/openresty_http_e2e.sh
# OpenResty HTTP 端到端测试：启动 nginx + 运行 HTTP E2E 测试 + 停止 nginx
#
# 运行：bash test/openresty_http_e2e.sh
#
# 测试内容：
#   1. nginx content_by_lua 上下文中的 handle_message 正确工作
#   2. cosocket 客户端通过 HTTP 调用 YAR 服务端
#   3. lua-resty-http provider 委托真实 HTTP 往返
#   4. keepalive 连接池复用
#   5. 并发请求（多协程）

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NGINX_PREFIX="/tmp/yar_nginx_test"
HTTP_E2E_PORT="${HTTP_E2E_PORT:-9702}"

# 端口分配见 test/PORTS.md（openresty job: 9702=HTTP E2E）

cd "$PROJECT_ROOT"

# 加载共享测试函数（端口清理等）
source "$SCRIPT_DIR/test_helpers.sh"

# 检查 openresty 可用
OPENRESTY="${OPENRESTY:-openresty}"
if [ -x /usr/local/openresty/bin/openresty ]; then
    OPENRESTY="/usr/local/openresty/bin/openresty"
elif command -v openresty &>/dev/null; then
    OPENRESTY="openresty"
else
    echo "[SKIP] openresty not found, skipping HTTP E2E tests"
    exit 0
fi

echo "=== OpenResty HTTP E2E Test ==="
echo ""

# 清理本脚本旧实例（只清理自己的 prefix，不影响其他 nginx 实例）
cleanup_nginx "$NGINX_PREFIX"
sleep 0.5
rm -rf "$NGINX_PREFIX"
mkdir -p "$NGINX_PREFIX/logs"

# 端口占用检测（不杀别人的进程，等待 5 秒）
wait_port_free "$HTTP_E2E_PORT"

# 生成 nginx.conf（用绝对路径替换 $PWD，因为 nginx 把 $PWD 当变量）
cat > "$NGINX_PREFIX/nginx.conf" << EOF
worker_processes  1;
error_log  $NGINX_PREFIX/logs/error.log  warn;
pid        $NGINX_PREFIX/nginx.pid;

events {
    worker_connections  256;
}

http {
    lua_package_path "$PROJECT_ROOT/src/?.lua;$PROJECT_ROOT/src/?/init.lua;$PROJECT_ROOT/test/?.lua;;";

    init_by_lua_block {
        require("test.nginx_e2e_server")
    }

    server {
        listen 127.0.0.1:$HTTP_E2E_PORT;
        server_name localhost;

        location /api {
            content_by_lua_block {
                require("test.nginx_e2e_server").serve()
            }
        }

        location /health {
            content_by_lua_block {
                ngx.print("ok")
            }
        }
    }
}
EOF

# 启动 nginx
echo "[1/4] Starting OpenResty nginx..."
$OPENRESTY -p "$NGINX_PREFIX" -c "$NGINX_PREFIX/nginx.conf"
sleep 1

# 健康检查
echo "[2/4] Health check..."
if curl -s http://127.0.0.1:$HTTP_E2E_PORT/health 2>/dev/null | grep -q "ok"; then
    echo "  nginx is healthy"
else
    echo "  [FAIL] nginx health check failed"
    cat "$NGINX_PREFIX/logs/error.log" 2>/dev/null | tail -5
    $OPENRESTY -p "$NGINX_PREFIX" -s stop 2>/dev/null || true
    exit 1
fi

# 运行 HTTP E2E 测试（通过 resty CLI）
# 注意：set -e 下失败命令会立即退出，无法捕获退出码，这里临时关闭
echo "[3/4] Running HTTP E2E tests..."
RESTY="${RESTY:-resty}"
if [ -x /usr/local/openresty/bin/resty ]; then
    RESTY="/usr/local/openresty/bin/resty"
elif command -v resty &>/dev/null; then
    RESTY="resty"
else
    echo "  [SKIP] resty CLI not found"
    $OPENRESTY -p "$NGINX_PREFIX" -s stop 2>/dev/null || true
    exit 0
fi

set +e
$RESTY "$SCRIPT_DIR/openresty_http_e2e_test.lua"
TEST_RESULT=$?
set -e

# 停止 nginx
echo "[4/4] Stopping OpenResty nginx..."
$OPENRESTY -p "$NGINX_PREFIX" -s stop 2>/dev/null || true
sleep 1

echo ""
if [ $TEST_RESULT -eq 0 ]; then
    echo "=== HTTP E2E tests PASSED ==="
else
    echo "=== HTTP E2E tests FAILED ==="
    exit 1
fi
