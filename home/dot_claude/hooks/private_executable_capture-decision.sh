#!/usr/bin/env bash
# capture-decision.sh — PostToolUse hook (matcher: AskUserQuestion)
#
# 人間との二者択一判断(AskUserQuestion)が確定した直後に、その判断を理由・文脈
# 付きで Obsidian の Decisions ノートへ記録するよう additionalContext で促す。
# 回答内容のパースはしない(モデルは自分の context に Q&A を保持しているため)。
# jq があれば質問文を best-effort で添えるだけ(失敗時は汎用文言へフォールバック)。
#
# 1 ctx 1 回: 判断の多いセッションで同文リマインダが数十回積まれるノイズを避けるため、
# 同一コンテキストへは初回のみ注入する。フラグ decision-nudged-${ctx}(flag-paths.sh が
# 単一情報源)。ctx は transcript_path 基準(session_id は subagent と共有される
# dotfiles#62)。rearm-coding-standards.sh(clear|compact)がフラグを破棄して再武装し、
# 新しい文脈では再注入を許す。抑制はベストエフォート: flag-paths.sh 不達 / 版ずれ /
# ctx 不明はすべて「毎回注入」へ倒す(注入欠落より毎回注入=現状維持を選ぶ)。
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

# 同一コンテキストへは初回のみ注入する(1 ctx 1 回)。キー導出は flag-paths.sh
# (単一情報源)で rearm-coding-standards.sh(clear|compact でフラグ破棄)と完全一致
# させる。flag-paths.sh 不達 / 版ずれ(新関数不在)/ ctx 不明はすべて ctx 空のまま =
# 毎回注入へ倒す(fail-open。抑制はベストエフォート)。
ctx=""
if source_hook_lib flag-paths.sh && type decision_nudged_flag >/dev/null 2>&1; then
  ctx="$(hook_field '.transcript_path // .session_id')"
  ctx="$(flag_ctx_key "$ctx" 2>/dev/null || true)"
fi
# seen: 既にこの ctx で注入済みなら無音素通り。
[[ -n "$ctx" && -f "$(decision_nudged_flag "$ctx")" ]] && exit 0

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

# mark は出力成功後に立てる(出力前に立てると jq 失敗時にフラグだけ残り注入が欠落する)。
# state dir 書込不能でも注入自体は済んでいるため、失敗は握って毎回注入=現状維持へ倒す。
[[ -n "$ctx" ]] && { claude_flag_dir_ensure && touch "$(decision_nudged_flag "$ctx")"; } 2>/dev/null || true

exit 0
