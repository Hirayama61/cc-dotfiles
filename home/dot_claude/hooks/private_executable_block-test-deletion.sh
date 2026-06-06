#!/usr/bin/env bash
# PreToolUse hook (Bash|Edit|MultiEdit): AI によるテストファイル/テストコードの
# 削除をブロックする。根拠: AI がテストを削除してテストを通す傾向がある。
# 安全側設計: jq 無しなら exit 0。
set -euo pipefail

if ! command -v jq &>/dev/null; then
  exit 0
fi

input="$(cat)"
tool_name="$(echo "$input" | jq -r '.tool_name // empty')"

# ディレクトリ枝の末尾 / は任意(rm -rf src/tests は末尾 / を付けない自然形が主目的シナリオ)。
# /tests? は前方 / を必須にして contests/protests を過剰ブロックしない。末尾境界は / ・行末・空白。
test_file_pattern='(\.(test|spec)\.[a-zA-Z]+|(__tests__|/tests?)(/|$|[[:space:]]))'

# --- Bash: rm / git rm によるテストファイル削除をブロック ---
if [[ "$tool_name" == "Bash" ]]; then
  command="$(echo "$input" | jq -r '.tool_input.command // empty')"
  [[ -z "$command" ]] && exit 0

  if echo "$command" | grep -qE '(^|\s|;|&&|\|\|)\s*(rm|git\s+rm)\s' && \
     echo "$command" | grep -qE "$test_file_pattern"; then
    echo "ブロック: テストファイルの削除は禁止。テストが失敗するならテストコードを修正すること。" >&2
    exit 2
  fi
  exit 0
fi

# --- Edit/MultiEdit: テストコード(アサーション)の削除をブロック ---
assertion_pattern='\b(it|test|describe|expect|assert|cy)\s*[\.(]|\.(should|toBe|toEqual|toHaveBeenCalled|toThrow|toMatch|toContain)\s*\('

# 1 件の編集(old/new ペア)がアサーション削除/非テスト置換なら exit 2、そうでなければ return 0。
check_edit() {
  local old_string="$1" new_string="$2"
  [[ -z "$old_string" ]] && return 0
  echo "$old_string" | grep -qE "$assertion_pattern" || return 0

  if [[ -z "$new_string" ]]; then
    echo "ブロック: テストコード(アサーション)の削除は禁止。失敗するならテストを修正すること。" >&2
    exit 2
  fi

  echo "$new_string" | grep -qE "$assertion_pattern" && return 0

  echo "ブロック: テストコード(アサーション)を非テストコードへ置換するのは禁止。" >&2
  exit 2
}

if [[ "$tool_name" == "Edit" ]]; then
  file_path="$(echo "$input" | jq -r '.tool_input.file_path // empty')"
  [[ -z "$file_path" ]] && exit 0
  echo "$file_path" | grep -qE "$test_file_pattern" || exit 0

  old_string="$(echo "$input" | jq -r '.tool_input.old_string // empty')"
  new_string="$(echo "$input" | jq -r '.tool_input.new_string // empty')"
  check_edit "$old_string" "$new_string"
  exit 0
fi

if [[ "$tool_name" == "MultiEdit" ]]; then
  file_path="$(echo "$input" | jq -r '.tool_input.file_path // empty')"
  [[ -z "$file_path" ]] && exit 0
  echo "$file_path" | grep -qE "$test_file_pattern" || exit 0

  # 各 edit の old/new を NUL 区切りで交互に出し pairwise で読む(改行を含む値でも安全)。
  while IFS= read -r -d '' old_string && IFS= read -r -d '' new_string; do
    check_edit "$old_string" "$new_string"
  done < <(echo "$input" | jq -r --raw-output0 '.tool_input.edits[]? | (.old_string // ""), (.new_string // "")')
  exit 0
fi

exit 0
