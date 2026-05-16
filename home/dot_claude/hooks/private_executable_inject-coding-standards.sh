#!/usr/bin/env bash
# inject-coding-standards.sh — PreToolUse hook (Edit|Write|MultiEdit|NotebookEdit)
#
# コード編集の瞬間に正典のコーディング規約を additionalContext として注入する。
# 正典は ~/.claude/coding-standards.md(cc-dotfiles が単一ソースとして所有)。
# 出典: 自リポ設計。additionalContext の出力形は pipe-stage-permissions.sh を流用。
#
# 安全側設計: 注入の失敗で編集をブロックしない。jq 不在 / 規約ファイル不在 /
# 想定外のエラーはすべて exit 0 で素通り(コンテキスト注入は best-effort)。
set -euo pipefail

command -v jq &>/dev/null || exit 0

STD="$HOME/.claude/coding-standards.md"
[[ -f "$STD" ]] || exit 0

# stdin は読むが file_path 等は使わない(matcher で対象を絞っているため、
# ここに来た時点でコード編集ツール。全件に規約を注入する)。
cat >/dev/null || true

jq -n --rawfile body "$STD" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: $body
  }
}' || exit 0

exit 0
