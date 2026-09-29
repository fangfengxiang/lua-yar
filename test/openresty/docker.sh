#!/bin/bash
# test/openresty/docker.sh
# Docker 方式运行 OpenResty 测试（无需本地安装任何依赖）
#
# 用法：
#   bash test/openresty/docker.sh                                          # 跑并发测试（HTTP + TCP）
#   bash test/openresty/docker.sh test/openresty/concurrent_openresty.sh http   # 仅 HTTP
#   bash test/openresty/docker.sh test/openresty/concurrent_openresty.sh tcp    # 仅 TCP
#   bash test/openresty/docker.sh test/openresty_http_e2e.sh                # HTTP E2E
#
# 源码通过 volume 挂载，改代码后直接重跑，无需 rebuild 镜像
# 镜像只在依赖变化时才需要 rebuild

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IMAGE_NAME="lua-yar-openresty"
TARGET_SCRIPT="${1:-test/openresty/concurrent_openresty.sh}"

echo "[docker] Building image $IMAGE_NAME (cached if unchanged)..."
docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"

echo "[docker] Running: $TARGET_SCRIPT"
echo "[docker] Project mounted at /app"
echo ""

docker run --rm \
    -v "$PROJECT_ROOT:/app" \
    -w /app \
    "$IMAGE_NAME" \
    bash "$TARGET_SCRIPT"
