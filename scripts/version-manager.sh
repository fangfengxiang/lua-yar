#!/usr/bin/env bash
# version-manager.sh — lua-yar 版本号管理 (纯 shell, 无 python/json)
#
# 由 .versions 驱动 — 所有版本号来源的单一真相源。
# 新增版本文件只需在 txt 追加一行, 无需改脚本。
#
# 用法:
#   ./scripts/version-manager.sh sync  <version>   更新所有来源到 <version>
#   ./scripts/version-manager.sh check <version>   校验所有来源是否一致
#   ./scripts/version-manager.sh list              输出所有来源路径(供 git add)
#
# sync 退出码: 0=全部已一致(无变更), 1=有文件被修改
# check 退出码: 0=全部一致, 1=有不一致(CI 应在此失败)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$SCRIPT_DIR/../.versions"
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

# ── 提取当前版本 (捕获组1); 无匹配返回空 ──
extract_version() {
  local path="$1" regex="$2"
  grep -oE "$regex" "$path" 2>/dev/null | head -1 | sed -E "s/$regex/\1/" || true
}

# ── sync 单个文件; 返回 0=已改, 1=未改 ──
sync_one() {
  local path="$1" scope="$2" regex="$3" version="$4"
  local current
  current=$(extract_version "$path" "$regex")
  if [ -z "$current" ]; then
    printf "  ! %s (%s): pattern not found, skipping\n" "$path" "$scope"
    return 1
  fi
  if [ "$current" = "$version" ]; then
    printf "  = %s (%s): already %s\n" "$path" "$scope" "$version"
    return 1
  fi
  # 在匹配 regex 的行, 用 index() 做字面替换 (无正则, 无需转义版本号)
  export AWK_RE="$regex" AWK_OLD="$current" AWK_NEW="$version"
  awk '
    $0 ~ ENVIRON["AWK_RE"] {
      o = ENVIRON["AWK_OLD"]; n = ENVIRON["AWK_NEW"]
      p = index($0, o)
      if (p > 0) $0 = substr($0, 1, p-1) n substr($0, p + length(o))
    }
    { print }
  ' "$path" > "$TMPFILE" && cp "$TMPFILE" "$path"
  printf "  ~ %s (%s): %s -> %s\n" "$path" "$scope" "$current" "$version"
  return 0
}

# ── check 单个文件; 返回 0=一致, 1=不一致 ──
check_one() {
  local path="$1" scope="$2" regex="$3" version="$4"
  local current
  current=$(extract_version "$path" "$regex")
  if [ -z "$current" ]; then
    printf "  ::error::%s (%s): version pattern not found\n" "$path" "$scope"
    return 1
  fi
  if [ "$current" = "$version" ]; then
    printf "  ok %s (%s): %s\n" "$path" "$scope" "$current"
    return 0
  fi
  printf "  XX %s (%s): %s != %s\n" "$path" "$scope" "$current" "$version"
  printf "  ::error::%s version (%s) does not match target (%s)\n" \
    "$path" "$current" "$version"
  return 1
}

# ── sync: 更新所有来源; 返回 1=有变更, 0=无变更 ──
cmd_sync() {
  local version="$1" changed=0 path scope regex line
  echo "=== sync version sources to $version ==="
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    read -r path scope regex <<< "$line"
    [ -z "$path" ] && continue
    if sync_one "$path" "$scope" "$regex" "$version"; then
      changed=1
    fi
  done < "$MANIFEST"
  if [ "$changed" = "1" ]; then
    echo "synced version sources to $version"
  else
    echo "all version sources already at $version"
  fi
  return "$changed"
}

# ── check: 校验所有来源; 返回 0=全一致, 1=有不一致 ──
cmd_check() {
  local version="$1" ok=1 total=0 fail=0 path scope regex line
  echo "=== check version sources against $version ==="
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    read -r path scope regex <<< "$line"
    [ -z "$path" ] && continue
    total=$((total + 1))
    if check_one "$path" "$scope" "$regex" "$version"; then :; else
      ok=0; fail=$((fail + 1))
    fi
  done < "$MANIFEST"
  if [ "$ok" = "1" ]; then
    echo "all $total version sources match $version"
    return 0
  fi
  echo "::error::$fail/$total version sources mismatch."
  echo "  Run: ./scripts/version-manager.sh sync $version"
  return 1
}

# ── list: 输出所有来源路径 ──
cmd_list() {
  local path scope regex line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    read -r path scope regex <<< "$line"
    [ -z "$path" ] && continue
    printf '%s\n' "$path"
  done < "$MANIFEST"
}

usage() {
  sed -n '2,/^$/s/^# \?//p' "$0"
}

main() {
  if [ $# -lt 1 ]; then usage; return 2; fi
  local cmd="$1"
  case "$cmd" in
    sync)  [ $# -ge 2 ] || { usage; return 2; }; cmd_sync "$2" ;;
    check) [ $# -ge 2 ] || { usage; return 2; }; cmd_check "$2" ;;
    list)  cmd_list ;;
    -h|--help|help) usage ;;
    *) echo "unknown command: $cmd" >&2; usage; return 2 ;;
  esac
}

main "$@"
