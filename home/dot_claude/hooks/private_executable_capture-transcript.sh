#!/usr/bin/env bash
# capture-transcript.sh — UserPromptSubmit hook
#
# 決定ログ(decisions.jsonl)へユーザー発話を逐語で機械追記し、ターンカウンタを進める。
# 決定ログは「人間側が発した情報のみ」をモデル非介在で残す一次記録で、compact 前の
# state file(compact-prep skill)の欠落検知の照合元になる。UserPromptSubmit はメイン
# セッションでのみ発火するため、ここでの記録は自然にメイン限定になる。
#
# あわせて 50% ゲート(context-pressure-gate.sh)の人間専用脱出口を受ける:
# プロンプトに override フレーズが含まれたら override marker を書く(1 回分)。
# フレーズは deny 理由には出さない(人間向け案内は README のみ。Claude に自己解除させない)。
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

ctx="$(claude_ctx_key "$(hook_field '.transcript_path')")"
[[ -z "$ctx" ]] && exit 0

prompt="$(hook_field '.prompt')"
[[ -z "$prompt" ]] && exit 0

# 決定ログには機密が混じりうるため、作るファイルはすべて 0600 に固める
umask 077
claude_ctx_cache_ensure "$ctx" || exit 0

# ターンカウンタ(50% ゲートの猶予 1 ターン判定が読む)
turn_file="$(ctx_turn_file "$ctx")"
turn="$(cat "$turn_file" 2>/dev/null || echo 0)"
case "$turn" in *[!0-9]* | "") turn=0 ;; esac
turn=$((turn + 1))
printf '%s' "$turn" > "$turn_file" 2>/dev/null || true

# override フレーズ(人間専用の 1 回解除)。会話中の言及・引用での誤発動を避けるため
# 「単独行としての完全一致」(前後空白は許容)に限定する。
if printf '%s\n' "$prompt" | grep -qxE '[[:space:]]*context-gate-override[[:space:]]*'; then
  touch "$(ctx_override_marker "$ctx")" 2>/dev/null || true
fi

printf '%s' "$HOOK_INPUT" | jq -c --argjson turn "$turn" --arg ts "$(date '+%Y-%m-%dT%H:%M:%S')" \
  '{ts: $ts, turn: $turn, type: "prompt", content: .prompt}' \
  >> "$(ctx_decisions_file "$ctx")" 2>/dev/null || true

exit 0
