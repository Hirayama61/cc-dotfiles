#!/usr/bin/env bash
# PreToolUse(Bash): 保護ブランチ(main/master/develop/epic/**)への
# push / merge を物理的にブロックする。人間の許可なき不可逆操作を防ぐ。
# 安全側設計: jq 無し / git 外 / ブランチ不明なら exit 0(通す)。
set -euo pipefail

command -v jq &>/dev/null || exit 0
input="$(cat)"
cmd="$(echo "$input" | jq -r '.tool_input.command // empty')"
[[ -z "$cmd" ]] && exit 0

# git push / git merge を含まなければ対象外(チェイン対応で行頭アンカーなし)。
# 末尾は (\s|$) で区切り、merge-base/merge-tree/merge-file 等 read-only
# plumbing(直後が `-`)を \b の単語境界で誤ブロックしないようにする。
echo "$cmd" | grep -qE '\bgit\s+(push|merge)(\s|$)' || exit 0

git rev-parse --is-inside-work-tree &>/dev/null 2>&1 || exit 0
branch="$(git branch --show-current 2>/dev/null || echo "")"
[[ -z "$branch" ]] && exit 0

is_protected() {
  [[ "$1" == "main" || "$1" == "master" || "$1" == "develop" || "$1" == epic/* ]]
}

# push: 現在のブランチが保護対象なら拒否
if echo "$cmd" | grep -qE '\bgit\s+push(\s|$)' && is_protected "$branch"; then
  echo "ブロック: 保護ブランチ(${branch})への push は禁止。feature ブランチから人間が PR を作成すること。" >&2
  exit 2
fi

# merge: 保護ブランチ上での merge(= 保護ブランチへのマージ)を拒否
if echo "$cmd" | grep -qE '\bgit\s+merge(\s|$)' && is_protected "$branch"; then
  echo "ブロック: 保護ブランチ(${branch})への merge は禁止。人間の判断を経ること。" >&2
  exit 2
fi

exit 0
