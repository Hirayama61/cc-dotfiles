#!/usr/bin/env bash
# context-pressure-gate.sh — PreToolUse(Edit|Write|MultiEdit|NotebookEdit): 50% 最終通告ライン
#
# コンテキスト使用率 50% 以上での新規作業を止める(50% 超の劣化した判断で作業を
# 続けさせない)。猶予 1 ターン: 検知ターンは編集を通しつつ警告を注入し(作業単位を
# 閉じる余地)、次ターンから exit 2 で遮断する。猶予の長さは機械が持ち、Claude 自身に
# 「もう少し」を判断させない。
#
# 不変条件: ゲートは脱出行動を塞がない。
#   - Bash は matcher に含めない(compact-prep の validate-state.sh / pbcopy が
#     deny される自己デッドロックの回避。design-review F-001)
#   - cache dir 配下(state file 等)への Write は素通し
#   - override marker(人間専用。capture-transcript.sh が受け付ける)で 1 回解除
#
# subagent 配下は素通し(使用率はメインの context しか表さず、逼迫時の正しい対処は
# 委譲そのもの。ゲートが委譲先を止めると唯一の逃げ道を塞ぐ)。判別は agent_id キー。
#
# 安全側設計: usage.json 不在 / stale / turn 不明はすべて素通し(fail-open)。
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

usage_file="$(ctx_usage_file "$ctx")"
[[ -r "$usage_file" ]] || exit 0

pct="$(jq -r '.pct // empty' "$usage_file" 2>/dev/null || true)"
updated_at="$(jq -r '.updated_at // empty' "$usage_file" 2>/dev/null || true)"
case "$pct" in "" | *[!0-9.]*) exit 0 ;; esac
case "$updated_at" in "" | *[!0-9]*) exit 0 ;; esac
now="$(date +%s)"
(( now - updated_at > 1800 )) && exit 0
pct_int="${pct%%.*}"
case "$pct_int" in "" | *[!0-9]*) exit 0 ;; esac

(( pct_int < 50 )) && exit 0

# state file 等の cache 配下への書込は脱出経路なので通す
fp="$(hook_field '.tool_input.file_path // .tool_input.notebook_path')"
cache_dir="$(claude_ctx_cache_dir "$ctx")"
case "$fp" in
"$cache_dir"/*) exit 0 ;;
esac

# 人間専用の 1 回解除
override="$(ctx_override_marker "$ctx")"
if [[ -f "$override" ]]; then
  rm -f "$override" 2>/dev/null || true
  exit 0
fi

turn="$(cat "$(ctx_turn_file "$ctx")" 2>/dev/null || true)"
case "$turn" in "" | *[!0-9]*) exit 0 ;; esac

grace_file="$(ctx_grace_turn_file "$ctx")"
grace="$(cat "$grace_file" 2>/dev/null || true)"

if [[ -z "$grace" ]]; then
  # 検知ターン: 猶予を記録し、警告注入つきで通す
  claude_ctx_cache_ensure "$ctx" || exit 0
  printf '%s' "$turn" > "$grace_file" 2>/dev/null || exit 0
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: "コンテキスト使用率 50% 超(最終通告ライン)。猶予はこのターンのみ。現在の作業単位を閉じることだけを行い、新規の作業単位を開始するな。作業単位を閉じたら compact-prep skill を実行して state file を書き、人間に /compact の実行を依頼せよ。次のターンから編集系ツールはブロックされる。"
    }
  }' || exit 0
  exit 0
fi

case "$grace" in "" | *[!0-9]*) exit 0 ;; esac
(( turn <= grace )) && exit 0

echo "ブロック: コンテキスト使用率 50% 超で猶予ターンを過ぎた。これ以上の編集は行えない。compact-prep skill を実行して state file を書き、人間に /compact の実行を依頼せよ(/compact 後に自動で解除される)。" >&2
exit 2
