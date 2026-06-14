#!/usr/bin/env bash
# PostToolUse(Edit|Write|MultiEdit): 大きいファイル / 単一 Write の一括書き込みを警告のみで
# 可視化する(ブロックしない)。既存テストファイルへの一括 Write でテスト観点を無言で
# 失う事故の上流予防として、肥大と全置換の規模を注意喚起に出す。
#
# warn-only: 常に exit 0。hookSpecificOutput.additionalContext にメッセージを注入する。
# console.log / secret 検出は含めない(block-secret-files と git pre-commit の
# sensitive-words で被覆済み)。閾値 500 行は暫定で実運用で調整する前提。
# fail-open: jq 不在 / path 不明 / 非ファイルは素通し。
set -euo pipefail

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0
file_path="$(hook_file_path)"
[[ -z "$file_path" ]] && exit 0
[[ -f "$file_path" ]] || exit 0
tool_name="$(hook_tool_name)"

# 巨大ファイル(50MB 超)は wc -l の全読みを避けてサイズだけで警告する
# (hook が timeout まで I/O を占有しないため)。
size="$(stat -f %z "$file_path" 2>/dev/null || echo 0)"
if [[ "$size" =~ ^[0-9]+$ ]] && ((size > 50 * 1024 * 1024)); then
  printf '%s' "ファイルが $((size / 1024 / 1024))MB あります。責務分割を検討してください。" |
    jq -Rs '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:.}}' 2>/dev/null || true
  exit 0
fi

line_count="$(wc -l < "$file_path" 2>/dev/null | tr -d ' ')" || exit 0
[[ "$line_count" =~ ^[0-9]+$ ]] || exit 0

warn=""
# Write は新規作成または既存ファイルの全置換。PostToolUse では置換前の状態を取れない
# ため、「Write かつ大行数」を全置換の近似シグナルとして観点喪失に注意喚起する。
if [[ "$tool_name" == "Write" && "$line_count" -gt 500 ]]; then
  warn="単一 Write で ${line_count} 行(500 行超)を一括書き込みしました。新規作成または既存ファイルの全置換であり、後者はテスト観点等を無言で失う恐れがあります。責務分割と差分の意図確認を検討してください。"
elif [[ "$line_count" -gt 500 ]]; then
  warn="ファイルが ${line_count} 行あります(500 行超)。責務分割を検討してください。"
fi

[[ -z "$warn" ]] && exit 0

printf '%s' "$warn" | jq -Rs '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:.}}' 2>/dev/null || exit 0
exit 0
