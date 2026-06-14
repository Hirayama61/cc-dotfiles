#!/usr/bin/env bash
# PreToolUse hook (Bash|Edit): AI によるテストファイル/テストコードの削除を
# ブロックする。根拠: AI がテストを削除してテストを通す傾向がある。
# 判定 ERE は test-patterns.sh(単一情報源)から取る。
# 安全側設計: jq 無し / lib 不達なら exit 0。
set -euo pipefail

PATTERN_LIB="$HOME/.claude/hooks/lib/test-patterns.sh"
[[ -r "$PATTERN_LIB" ]] || exit 0
# 構文破損 lib を直接 source すると bash が status 2 で即死し「ブロック」に化けるため、
# subshell で読めるか先に検査してから本 source する(fail-open)。
# shellcheck source=/dev/null
( . "$PATTERN_LIB" ) >/dev/null 2>&1 || exit 0
. "$PATTERN_LIB" 2>/dev/null || exit 0

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0
tool_name="$(hook_tool_name)"

test_file_pattern="$(test_file_ere)"
[[ -n "$test_file_pattern" ]] || exit 0

# --- Bash: rm / git rm によるテストファイル削除をブロック ---
if [[ "$tool_name" == "Bash" ]]; then
  command="$(hook_command)"
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
  file_path="$(hook_file_path)"
  [[ -z "$file_path" ]] && exit 0

  printf '%s' "$file_path" | grep -qE "$test_file_pattern" || exit 0

  old_string="$(hook_field '.tool_input.old_string')"
  new_string="$(hook_field '.tool_input.new_string')"
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
