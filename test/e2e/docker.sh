#!/bin/bash
# test/e2e/docker.sh
# Docker 方式运行 E2E 测试（无需本地安装任何依赖）
#
# 用法：
#   bash test/e2e/docker.sh                          # 跑 test/e2e/interop.sh
#   bash test/e2e/docker.sh test/e2e/check_env.sh    # 环境检查
#   bash test/e2e/docker.sh test/e2e/concurrent_e2e.sh    # 并发测试
#
# 源码通过 volume 挂载，改代码后直接重跑，无需 rebuild 镜像
# 镜像只在依赖变化时才需要 rebuild

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IMAGE_NAME="lua-yar-e2e"
TARGET_SCRIPT="${1:-test/e2e/interop.sh}"

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
