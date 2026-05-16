#!/usr/bin/env bash
# PreToolUse(Bash): セルフレビュー未通過のブランチからの push をブロックする。
# 目的は「push 禁止」ではなく「push 前に必ずセルフレビューを通す」強制。
# フラグは self-review スキルが通過時に作成する。コミットで無効化される
# (postcommit-invalidate-review.sh)。安全側設計: 不明なら exit 0。
set -euo pipefail

command -v jq &>/dev/null || exit 0
input="$(cat)"
cmd="$(echo "$input" | jq -r '.tool_input.command // empty')"
[[ -z "$cmd" ]] && exit 0

echo "$cmd" | grep -qE '\bgit\s+push\b' || exit 0

git rev-parse --is-inside-work-tree &>/dev/null 2>&1 || exit 0
branch="$(git branch --show-current 2>/dev/null || echo "")"
[[ -z "$branch" ]] && exit 0

# 保護ブランチは block-protected-branch-push.sh が専任。ここでは二重メッセージを避け通す
case "$branch" in
  main|master|develop|epic/*) exit 0 ;;
esac

safe_branch="$(echo "$branch" | tr '/' '-')"
flag_dir="/tmp/claude-sessions"
flag_file="${flag_dir}/review-passed-${safe_branch}"
mkdir -p "$flag_dir"

if [[ ! -f "$flag_file" ]]; then
  echo "ブロック: ブランチ(${branch})はセルフレビュー未通過。push 前に /self-review を実施すること(通過でゲート解除。新規コミットで再レビュー必須)。" >&2
  exit 2
fi

exit 0
