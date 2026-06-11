#!/usr/bin/env bash
# PreToolUse hook (Bash|Edit): AI によるテストファイル/テストコードの削除を
# ブロックする。根拠: AI がテストを削除してテストを通す傾向がある。
# 判定 ERE は test-patterns.sh(単一情報源)から取る。
# 安全側設計: jq 無し / lib 不達なら exit 0。
set -euo pipefail

if ! command -v jq &>/dev/null; then
  exit 0
fi

PATTERN_LIB="$HOME/.claude/hooks/lib/test-patterns.sh"
[[ -r "$PATTERN_LIB" ]] || exit 0
# shellcheck source=/dev/null
. "$PATTERN_LIB"

input="$(cat)"
tool_name="$(echo "$input" | jq -r '.tool_name // empty')"

test_file_pattern="$(test_file_ere)"
[[ -n "$test_file_pattern" ]] || exit 0

# --- Bash: rm / git rm によるテストファイル削除をブロック ---
if [[ "$tool_name" == "Bash" ]]; then
  command="$(echo "$input" | jq -r '.tool_input.command // empty')"
  [[ -z "$command" ]] && exit 0

  if printf '%s' "$command" | grep -qE '(^|\s|;|&&|\|\|)\s*(rm|git\s+rm)\s' && \
     printf '%s' "$command" | grep -qE "$test_file_pattern"; then
    echo "ブロック: テストファイルの削除は禁止。テストが失敗するならテストコードを修正すること。" >&2
    exit 2
  fi
  exit 0
fi

# --- Edit: テストコード(アサーション)の削除をブロック ---
if [[ "$tool_name" == "Edit" ]]; then
  file_path="$(echo "$input" | jq -r '.tool_input.file_path // empty')"
  [[ -z "$file_path" ]] && exit 0

  printf '%s' "$file_path" | grep -qE "$test_file_pattern" || exit 0

  old_string="$(echo "$input" | jq -r '.tool_input.old_string // empty')"
  new_string="$(echo "$input" | jq -r '.tool_input.new_string // empty')"
  [[ -z "$old_string" ]] && exit 0

  assertion_pattern="$(test_assertion_ere)"
  [[ -n "$assertion_pattern" ]] || exit 0

  printf '%s' "$old_string" | grep -qE "$assertion_pattern" || exit 0

  if [[ -z "$new_string" ]]; then
    echo "ブロック: テストコード(アサーション)の削除は禁止。失敗するならテストを修正すること。" >&2
    exit 2
  fi

  printf '%s' "$new_string" | grep -qE "$assertion_pattern" && exit 0

  echo "ブロック: テストコード(アサーション)を非テストコードへ置換するのは禁止。" >&2
  exit 2
fi

exit 0
