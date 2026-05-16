#!/usr/bin/env bash
# PostToolUse(Bash): git commit 実行後、そのブランチのセルフレビュー
# フラグを削除する。これにより「現在の成果物をレビューせず push」が
# 物理的に不可能になる(コミットのたびに再レビュー必須)。
# 安全側設計: 不明なら静かに exit 0(削除=保守的なので消し過ぎは無害)。
set -euo pipefail

command -v jq &>/dev/null || exit 0
input="$(cat)"
cmd="$(echo "$input" | jq -r '.tool_input.command // empty')"
[[ -z "$cmd" ]] && exit 0

# git commit を含むコマンドのみ対象
echo "$cmd" | grep -qE '\bgit\s+commit\b' || exit 0

git rev-parse --is-inside-work-tree &>/dev/null 2>&1 || exit 0
branch="$(git branch --show-current 2>/dev/null || echo "")"
[[ -z "$branch" ]] && exit 0

safe_branch="$(echo "$branch" | tr '/' '-')"
rm -f "/tmp/claude-sessions/review-passed-${safe_branch}"

exit 0
