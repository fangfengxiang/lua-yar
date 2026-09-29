#!/usr/bin/env bash
# release.sh — lua-yar 发版脚本
#
# 用法:
#   ./scripts/release.sh <version>
#
# 示例:
#   ./scripts/release.sh 0.2.0
#
# 脚本完成:
#   1. 验证版本号格式
#   2. 调用 version-manager.sh sync 同步所有版本号来源
#      (来源清单见 .versions)
#   3. 调用 version-manager.sh check 校验一致性
#   4. Git 提交
#
# CI 自动完成（无需本地操作）:
#   - prepare job 先跑 version-manager.sh sync 自动补齐（有变更则 commit+push main）
#   - 从 lua-yar-scm-1.rockspec 生成版本 rockspec
#   - 查询 luarocks.org 自动确定 revision
#   - 上传 LuaRocks / OPM
#   - 创建 GitHub Release
#
# 防呆设计:
#   版本号来源清单 .versions 是单一真相源，
#   version-manager.sh (本地 release.sh 和 CI release.yml) 共用，
#   新增版本文件只需改 txt，无需改脚本。

set -euo pipefail

PKG="lua-yar"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- 参数检查 ---
if [ $# -lt 1 ]; then
  echo "用法: $0 <version>"
  echo "示例: $0 0.2.0"
  exit 1
fi

VERSION="$1"
TAG="v${VERSION}"

# 验证版本号格式 x.x.x
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo -e "${RED}错误: 版本号格式必须为 x.x.x，当前输入: $VERSION${NC}"
  exit 1
fi

echo -e "${CYAN}=== lua-yar 发版准备: $TAG ===${NC}"
echo ""

# --- 同步版本号 ---
echo -e "${CYAN}[1/3] 同步版本号到所有来源...${NC}"
if bash "${SCRIPT_DIR}/version-manager.sh" sync "$VERSION"; then
  echo -e "  所有来源已是 ${VERSION}，无需修改"
else
  echo -e "  ${GREEN}已同步以下文件到 ${VERSION}${NC}"
fi

# --- 校验 ---
echo ""
echo -e "${CYAN}[2/3] 校验版本号一致性...${NC}"
bash "${SCRIPT_DIR}/version-manager.sh" check "$VERSION"

# --- Git 提交 ---
echo ""
echo -e "${CYAN}[3/3] Git 提交...${NC}"
git add $(bash "${SCRIPT_DIR}/version-manager.sh" list)
if git diff --cached --quiet; then
  echo -e "  ${YELLOW}无变更需要提交${NC}"
else
  git commit -m "release: bump to ${TAG}"
  echo -e "  ${GREEN}已提交${NC}"
fi

# --- 汇总 ---
echo ""
echo -e "${CYAN}=== 发版就绪 ===${NC}"
echo ""
echo "  包名:         $PKG"
echo "  版本:         $VERSION"
echo "  Tag:          $TAG"
echo "  版本来源:    .versions (一致性已由 check 验证)"
echo ""
echo -e "${GREEN}下一步:${NC}"
echo "  git push origin main"
echo "  git tag $TAG"
echo "  git push origin $TAG"
echo ""
echo -e "${YELLOW}打 tag 后 CI 自动执行:${NC}"
echo "  1. version-manager.sh sync 自动补齐版本号 (prepare job)"
echo "  2. version-manager.sh check 校验一致性"
echo "  3. 从 scm 生成版本 rockspec（revision 自动确定）"
echo "  4. 创建 GitHub Release"
echo "  5. 上传 LuaRocks"
echo "  6. 构建并上传 OPM"
