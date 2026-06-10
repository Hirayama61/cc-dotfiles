#!/usr/bin/env bash
# PostToolUse(Edit|Write): 大きいファイル / 単一 Write の一括書き込みを警告のみで
# 可視化する(ブロックしない)。既存テストファイルへの一括 Write でテスト観点を無言で
# 失う事故の上流予防として、肥大と全置換の規模を注意喚起に出す。
#
# warn-only: 常に exit 0。hookSpecificOutput.additionalContext にメッセージを注入する。
# console.log / secret 検出は含めない(block-secret-files と git pre-commit の
# sensitive-words で被覆済み)。閾値 500 行は暫定で実運用で調整する前提。
# fail-open: jq 不在 / path 不明 / 非ファイルは素通し。
set -euo pipefail

command -v jq &>/dev/null || exit 0
input="$(cat)"
file_path="$(echo "$input" | jq -r '.tool_input.file_path // empty')"
[[ -z "$file_path" ]] && exit 0
[[ -f "$file_path" ]] || exit 0
tool_name="$(echo "$input" | jq -r '.tool_name // empty')"

line_count="$(wc -l < "$file_path" 2>/dev/null | tr -d ' ')" || exit 0
[[ "$line_count" =~ ^[0-9]+$ ]] || exit 0

warn=""
if [[ "$line_count" -gt 500 ]]; then
  warn="ファイルが ${line_count} 行あります(500 行超)。責務分割を検討してください。"
fi
# Write は既存ファイルを全置換する。PostToolUse では置換前の行数を取れないため、
# 「Write かつ大行数」を全置換の近似シグナルとして観点喪失に注意喚起する。
if [[ "$tool_name" == "Write" && "$line_count" -gt 500 ]]; then
  warn="${warn:+$warn }単一 Write で ${line_count} 行を一括書き込みしました。既存ファイルの全置換はテスト観点等を無言で失う恐れがあるため、差分が意図どおりか確認してください。"
fi

[[ -z "$warn" ]] && exit 0

printf '%s' "$warn" | jq -Rs '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:.}}' 2>/dev/null || exit 0
exit 0
