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
#   2. 更新 dist.ini 版本号
#   3. Git 提交
#
# CI 自动完成（无需本地操作）:
#   - 从 lua-yar-scm-1.rockspec 生成版本 rockspec
#   - 查询 luarocks.org 自动确定 revision
#   - 上传 LuaRocks / OPM
#   - 创建 GitHub Release
#   - 生成 CITATION.cff

set -euo pipefail

PKG="lua-yar"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

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

# --- 更新 dist.ini ---
echo -e "${CYAN}[1/2] 更新 dist.ini...${NC}"
CURRENT_DIST_VER=$(grep '^version' dist.ini | awk '{print $3}')
if [ "$CURRENT_DIST_VER" = "$VERSION" ]; then
  echo -e "  dist.ini 已是 ${VERSION}，无需修改"
else
  sed -i '' "s/^version = .*/version = ${VERSION}/" dist.ini
  echo -e "  dist.ini: ${YELLOW}$CURRENT_DIST_VER${NC} → ${GREEN}$VERSION${NC}"
fi

# --- Git 提交 ---
echo ""
echo -e "${CYAN}[2/2] Git 提交...${NC}"
git add -A
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
echo "  包名:     $PKG"
echo "  版本:     $VERSION"
echo "  Tag:      $TAG"
echo "  dist.ini: $VERSION"
echo ""
echo -e "${GREEN}下一步:${NC}"
echo "  git push origin main"
echo "  git tag $TAG"
echo "  git push origin $TAG"
echo ""
echo -e "${YELLOW}打 tag 后 CI 自动执行:${NC}"
echo "  1. 从 scm 生成版本 rockspec（revision 自动确定）"
echo "  2. 创建 GitHub Release"
echo "  3. 上传 LuaRocks"
echo "  4. 构建并上传 OPM"
echo "  5. 生成 CITATION.cff"
