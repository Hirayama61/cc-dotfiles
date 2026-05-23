#!/usr/bin/env bash
# PreToolUse(Bash): push 前に wip コミットの整理を促すゲート。
# 未 push のコミットに wip: 接頭辞が1件以上あれば push を deny し、Claude に
# squash / reword で履歴を整えてから push するよう促す。自動 rebase はしない
# (履歴破壊は人間/Claude の判断に委ねる)。安全側設計: 不明なら exit 0(通す)。
set -euo pipefail

command -v jq &>/dev/null || exit 0
input="$(cat)"
cmd="$(echo "$input" | jq -r '.tool_input.command // empty')"
[[ -z "$cmd" ]] && exit 0

# git push を含まなければ対象外(既存 pre-push-selfreview-gate と同形の検知)。
echo "$cmd" | grep -qE '\bgit\s+push\b' || exit 0

git rev-parse --is-inside-work-tree &>/dev/null 2>&1 || exit 0

# 未 push 範囲を決定。upstream があれば upstream..HEAD、無ければ全 HEAD を走査
# (初回 push は履歴全部が未 push なので安全側で全走査)。
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "")"
if [[ -n "$upstream" ]]; then
  range="${upstream}..HEAD"
else
  range="HEAD"
fi

wip_count="$(git log --format='%s' "$range" 2>/dev/null | grep -cE '^wip:' || true)"
[[ -z "$wip_count" ]] && wip_count=0

if [[ "$wip_count" -ge 1 ]]; then
  reason="push 前ゲート: 未 push に wip: コミットが ${wip_count} 件あります。push 前に interactive rebase 等で squash / reword し、履歴を整えてから push してください(自動 squash / rebase はしません — 履歴整理は判断を要します)。"
  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
fi

exit 0
