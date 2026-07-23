#!/usr/bin/env bash
# capture-plan-qa.sh — PostToolUse hook (matcher: ExitPlanMode|AskUserQuestion)
#
# 決定ログ(decisions.jsonl)へ、承認された Plan 本文(ExitPlanMode)と人間の
# 二者択一回答(AskUserQuestion)を機械追記する。capture-transcript.sh の発話逐語と
# 合わせ、決定ログの 3 捕捉面(発話 / plan / Q&A)を構成する。
#
# subagent 配下では記録しない(サブエージェント発の判断をメインのログに混ぜない)。
# 判別は入力の agent_id キーの存在(メインスレッド発の入力には無い。spike 2026-07-03)。
#
# AskUserQuestion の tool_response は {questions, answers, annotations} 形式
# (transcript 実測 2026-07-23)。answers が取れない wire 変更時は questions のみ記録に縮退。
#
# 安全側設計: 記録の失敗で作業を止めない。すべて exit 0(fail-open)。
set -euo pipefail

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$LIB" ) >/dev/null 2>&1 || exit 0
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0
source_hook_lib context-paths.sh || exit 0
type claude_ctx_key >/dev/null 2>&1 || exit 0

[[ -n "$(hook_field '.agent_id')" ]] && exit 0

ctx="$(claude_ctx_key "$(hook_field '.transcript_path')")"
[[ -z "$ctx" ]] && exit 0

tool="$(hook_tool_name)"
case "$tool" in
ExitPlanMode | AskUserQuestion) ;;
*) exit 0 ;;
esac

claude_ctx_cache_ensure "$ctx" || exit 0

turn="$(cat "$(ctx_turn_file "$ctx")" 2>/dev/null || echo 0)"
case "$turn" in *[!0-9]* | "") turn=0 ;; esac

if [[ "$tool" == "ExitPlanMode" ]]; then
  printf '%s' "$HOOK_INPUT" | jq -c --argjson turn "$turn" --arg ts "$(date '+%Y-%m-%dT%H:%M:%S')" \
    'select((.tool_input.plan // "") != "") |
     {ts: $ts, turn: $turn, type: "plan", content: .tool_input.plan}' \
    >> "$(ctx_decisions_file "$ctx")" 2>/dev/null || true
else
  printf '%s' "$HOOK_INPUT" | jq -c --argjson turn "$turn" --arg ts "$(date '+%Y-%m-%dT%H:%M:%S')" \
    '{ts: $ts, turn: $turn, type: "qa",
      questions: [(.tool_input.questions // [])[] | .question // empty],
      answers: (.tool_response.answers // null)}' \
    >> "$(ctx_decisions_file "$ctx")" 2>/dev/null || true
fi

exit 0
