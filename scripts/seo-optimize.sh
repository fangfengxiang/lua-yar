#!/usr/bin/env bash
# seo-optimize.sh — mkdocs 产物 SEO 后处理
#
# 用法:
#   bash scripts/seo-optimize.sh site
#
# 脚本完成:
#   1. 遍历 site/**/*.html
#   2. 从已有 <title> 和 <meta name="description"> 提取每页标题和描述
#   3. 注入 Open Graph 标签 (og:title/description/url/type/site_name)
#   4. 注入 Twitter Card 标签 (summary)
#   5. 注入 JSON-LD 结构化数据 (SoftwareSourceCode schema)
#
# 设计原则:
#   - 纯 Bash + grep + awk，零额外依赖
#   - 不用 sed 直接注入（title/description 可能含 / & \ 导致 sed 转义炸裂）
#   - printf 写注入块到临时文件，awk getline 读取后插入 </head> 前

set -euo pipefail

SITE_DIR="${1:-site}"
BASE_URL="https://fangfengxiang.github.io/lua-yar"
REPO_URL="https://github.com/fangfengxiang/lua-yar"

if [ ! -d "$SITE_DIR" ]; then
  echo "Error: site directory '$SITE_DIR' not found" >&2
  exit 1
fi

# JSON-LD 结构化数据（全站统一，描述项目本身）
JSONLD='{"@context":"https://schema.org","@type":"SoftwareSourceCode","name":"lua-yar","description":"Lightweight concurrent Lua RPC framework","codeRepository":"https://github.com/fangfengxiang/lua-yar","programmingLanguage":"Lua","url":"https://fangfengxiang.github.io/lua-yar/"}'

count=0

# 用进程替换而非管道（管道的 while 在子 shell 中，count 无法回传）
while IFS= read -r -d '' f; do
  # 从 mkdocs 生成的 HTML 中提取已有的 title 和 description
  # 用 sed 而非 grep -oP（BSD grep 不支持 -P，CI Ubuntu 有但本地 macOS 无）
  title=$(sed -n 's/.*<title>\([^<]*\)<\/title>.*/\1/p' "$f" | head -1)
  desc=$(sed -n 's/.*name="description" content="\([^"]*\)".*/\1/p' "$f" | head -1)

  # 兜底默认值（无 front matter 的页面）
  [ -z "$desc" ] && desc="Yar RPC protocol implementation for Lua"
  [ -z "$title" ] && title="lua-yar"

  # 计算页面规范 URL: site/index.html → BASE_URL/
  #                 site/tutorial/index.html → BASE_URL/tutorial/
  rel="${f#$SITE_DIR}"
  url="$BASE_URL${rel%.html}"
  url="${url/\/index/}"

  # 生成注入块到临时文件（printf 避免转义问题）
  tmp=$(mktemp)
  {
    printf '<meta property="og:title" content="%s" />\n'        "$title"
    printf '<meta property="og:description" content="%s" />\n'  "$desc"
    printf '<meta property="og:url" content="%s" />\n'          "$url"
    printf '<meta property="og:type" content="website" />\n'
    printf '<meta property="og:site_name" content="lua-yar" />\n'
    printf '<meta name="twitter:card" content="summary" />\n'
    printf '<meta name="twitter:title" content="%s" />\n'        "$title"
    printf '<meta name="twitter:description" content="%s" />\n'  "$desc"
    printf '<script type="application/ld+json">%s</script>\n'    "$JSONLD"
  } > "$tmp"

  # 在 </head> 前插入注入块
  # awk: BEGIN 读注入文件到 block 变量，遇到 </head> 先输出 block 再输出当前行
  awk -v inj="$tmp" \
    'BEGIN{while((getline l<inj)>0)b=b l RS}/<\/head>/{printf"%s",b}1' \
    "$f" > "$f.tmp" && mv "$f.tmp" "$f"

  rm -f "$tmp"
  count=$((count + 1))
done < <(find "$SITE_DIR" -name '*.html' -print0)

echo "SEO meta tags injected into $count pages"
