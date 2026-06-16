#!/usr/bin/env bash
# capture-decision.sh — PostToolUse hook (matcher: AskUserQuestion)
#
# 人間との二者択一判断(AskUserQuestion)が確定した直後に、その判断を理由・文脈
# 付きで Obsidian の Decisions ノートへ記録するよう additionalContext で促す。
# 回答内容のパースはしない(モデルは自分の context に Q&A を保持しているため)。
# jq があれば質問文を best-effort で添えるだけ(失敗時は汎用文言へフォールバック)。
#
# 安全側設計: 注入の失敗で停止しない。jq 不在 / 非対象ツール / 想定外のエラーは
# すべて exit 0 で無音素通り(リマインドは best-effort)。
set -euo pipefail

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$LIB" ) >/dev/null 2>&1 || exit 0
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0

# matcher で AskUserQuestion に絞っているが、二重で確認(取りこぼし防止)。
tool="$(hook_tool_name)"
[[ "$tool" == "AskUserQuestion" ]] || exit 0

# best-effort: 質問文を抽出して文言に添える(wire 形式が違っても空でフォールバック)。
questions="$(printf '%s' "$HOOK_INPUT" | jq -r '
  (.tool_input.questions // []) | map(.question // empty) | map(select(. != "")) | join(" / ")
' 2>/dev/null || echo "")"

NOTE="直近で人間と判断を確定した。安全な切れ目(delegate 稼働中など)で、その判断を理由・文脈付きで Obsidian の Decisions ノートに記録せよ。timing とファイル分割はメインが判断する。"
[[ -n "$questions" ]] && NOTE="${NOTE}（確定した問い: ${questions}）"

jq -n --arg body "$NOTE" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $body
  }
}' || exit 0

exit 0
