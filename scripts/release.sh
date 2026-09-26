#!/usr/bin/env bash
# release.sh — lua-yar 发版脚本
#
# 用法:
#   ./scripts/release.sh <version>          # 自动检测下一个修订号
#   ./scripts/release.sh <version> <rev>    # 指定修订号
#
# 示例:
#   ./scripts/release.sh 0.1.1              # 自动检测，如已存在 0.1.1-1 则用 -2
#   ./scripts/release.sh 0.2.0              # 新版本，从 -1 开始
#
# 脚本会自动完成:
#   1. 检查 LuaRocks 上已存在的修订号，确定下一个可用修订号
#   2. 检查 OPM 上已存在的版本
#   3. 生成/更新 rockspec 文件
#   4. 更新 dist.ini 版本号
#   5. 清理同版本旧 rockspec
#   6. 提交 git commit
#
# 前置条件:
#   - curl, python3, git
#   - 在仓库根目录执行

set -euo pipefail

PKG="lua-yar"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 参数检查 ---
if [ $# -lt 1 ]; then
  echo "用法: $0 <version> [revision]"
  echo "示例: $0 0.1.1        # 自动检测修订号"
  echo "      $0 0.1.1 3      # 指定修订号 3"
  exit 1
fi

VERSION="$1"
REV="${2:-}"
TAG="v${VERSION}"

# 验证版本号格式 x.x.x
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo -e "${RED}错误: 版本号格式必须为 x.x.x，当前输入: $VERSION${NC}"
  exit 1
fi

echo -e "${CYAN}=== lua-yar 发版: $TAG ===${NC}"
echo ""

# --- 检查 LuaRocks 已有版本 ---
echo -e "${CYAN}[1/5] 检查 LuaRocks 已有版本...${NC}"
LUAROCKS_REVISIONS=""
if curl -sf "https://luarocks.org/manifests/fangfengxiang/manifest.json" 2>/dev/null | \
   python3 -c "
import sys, json
try:
    m = json.load(sys.stdin)
    vs = m.get('repository',{}).get('$PKG',{}).get('$VERSION',[])
    revs = [v.get('revision',0) for v in vs]
    if revs:
        print(' '.join(str(r) for r in sorted(revs)))
except: pass
" 2>/dev/null | read -r LUAROCKS_REVISIONS; then
  :
fi

if [ -n "$LUAROCKS_REVISIONS" ]; then
  echo -e "  LuaRocks 已有 ${PKG} ${VERSION} 修订号: ${YELLOW}$LUAROCKS_REVISIONS${NC}"
else
  echo -e "  LuaRocks 上无 ${PKG} ${VERSION}"
fi

# --- 确定修订号 ---
if [ -z "$REV" ]; then
  REV=1
  if [ -n "$LUAROCKS_REVISIONS" ]; then
    for r in $LUAROCKS_REVISIONS; do
      if [ "$r" -ge "$REV" ]; then
        REV=$((r + 1))
      fi
    done
  fi
  echo -e "  自动选择修订号: ${GREEN}$REV${NC}"
else
  # 检查指定修订号是否已存在
  for r in $LUAROCKS_REVISIONS; do
    if [ "$r" = "$REV" ]; then
      echo -e "${RED}错误: ${PKG} ${VERSION}-${REV} 已存在于 LuaRocks${NC}"
      echo -e "  已有修订号: $LUAROCKS_REVISIONS"
      echo -e "  建议使用:   $((REV + 1))"
      exit 1
    fi
  done
  echo -e "  使用指定修订号: ${GREEN}$REV${NC}"
fi

ROCKSPEC="${PKG}-${VERSION}-${REV}.rockspec"

# --- 检查 OPM 已有版本 ---
echo ""
echo -e "${CYAN}[2/5] 检查 OPM 已有版本...${NC}"
OPM_VERSIONS=""
if curl -sf "https://opm.openresty.org/api/pkg/fangfengxiang/${PKG}" 2>/dev/null | \
   python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    vs = [v.get('version','') for v in d.get('versions',[])]
    if vs:
        print(' '.join(sorted(vs)))
except: pass
" 2>/dev/null | read -r OPM_VERSIONS; then
  :
fi

if [ -n "$OPM_VERSIONS" ]; then
  echo -e "  OPM 已有版本: ${YELLOW}$OPM_VERSIONS${NC}"
  if echo "$OPM_VERSIONS" | grep -qw "$VERSION"; then
    echo -e "  ${YELLOW}警告: OPM 上已存在 ${VERSION}，上传会覆盖${NC}"
  fi
else
  echo -e "  OPM 上无 ${PKG} 或查询失败（不影响流程）"
fi

# --- 生成/更新 rockspec ---
echo ""
echo -e "${CYAN}[3/5] 生成 rockspec...${NC}"
if [ -f "$ROCKSPEC" ]; then
  echo -e "  ${YELLOW}$ROCKSPEC 已存在，跳过创建${NC}"
else
  TEMPLATE=$(ls ${PKG}-*.rockspec 2>/dev/null | grep -v scm | sort -V | tail -1)
  if [ -z "$TEMPLATE" ]; then
    echo -e "${RED}错误: 找不到模板 rockspec${NC}"
    exit 1
  fi
  sed -e "s/^version = \".*\"/version = \"${VERSION}-${REV}\"/" \
      -e "s/tag = \".*\"/tag = \"${TAG}\"/" \
      "$TEMPLATE" > "$ROCKSPEC"
  echo -e "  从 $TEMPLATE 生成 ${GREEN}$ROCKSPEC${NC}"
fi

# 清理同版本旧 rockspec
for f in ${PKG}-${VERSION}-*.rockspec; do
  if [ "$f" != "$ROCKSPEC" ] && [ -f "$f" ]; then
    echo -e "  清理旧文件: ${YELLOW}$f${NC}"
    rm "$f"
  fi
done

# --- 更新 dist.ini ---
echo ""
echo -e "${CYAN}[4/5] 更新 dist.ini...${NC}"
CURRENT_DIST_VER=$(grep '^version' dist.ini | awk '{print $3}')
if [ "$CURRENT_DIST_VER" = "$VERSION" ]; then
  echo -e "  dist.ini 已是 $VERSION，无需修改"
else
  sed -i '' "s/^version = .*/version = ${VERSION}/" dist.ini
  echo -e "  dist.ini: ${YELLOW}$CURRENT_DIST_VER${NC} → ${GREEN}$VERSION${NC}"
fi

# --- Git 提交 ---
echo ""
echo -e "${CYAN}[5/5] Git 提交...${NC}"
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
echo "  包名:       $PKG"
echo "  版本:       $VERSION"
echo "  修订号:     $REV"
echo "  Rockspec:   $ROCKSPEC"
echo "  Tag:        $TAG"
echo "  dist.ini:   $VERSION"
echo ""
echo -e "${GREEN}下一步:${NC}"
echo "  git push origin main"
echo "  git tag $TAG"
echo "  git push origin $TAG"
echo ""
echo -e "${YELLOW}打 tag 后 CI 自动执行:${NC}"
echo "  1. Lint rockspec"
echo "  2. 上传 LuaRocks ($ROCKSPEC)"
echo "  3. 创建 GitHub Release"
echo "  4. 构建并上传 OPM"
