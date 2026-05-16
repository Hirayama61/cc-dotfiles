#!/bin/bash
# pipe-stage-permissions.sh — PreToolUse hook for Claude Code
#
# Claude Codeのパーミッションシステムのバグを回避するHooks。
# パイプ/&&/; で繋がれたコマンドを個別ステージに分解し、
# 各ステージが settings.json の allow リストにマッチすれば自動承認する。
#
# 特徴:
# - クォート対応: grep -E "foo|bar" のパターン内 | を誤分割しない
# - 環境変数除去: CC=gcc make → make として判定
# - セキュリティ: PATH= 等の危険な環境変数は常にプロンプト表示

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

# コメント行と空行を除去
STRIPPED="$(echo "$COMMAND" | sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d')"
COMMAND="$STRIPPED"

if [ -z "$COMMAND" ]; then
  exit 0
fi

SETTINGS="$HOME/.claude/settings.json"
if [ ! -f "$SETTINGS" ]; then
  exit 0
fi

# settings.json から許可済みプレフィックスを抽出
# Bash(ls) → "ls", Bash(git status) → "git status" のように取り出す
ALLOWED_PREFIXES=()
while IFS= read -r line; do
  [ -n "$line" ] && ALLOWED_PREFIXES+=("$line")
done < <(
  jq -r '.permissions.allow[]? // empty' "$SETTINGS" |
  grep '^Bash(' |
  sed -n 's/^Bash(\(.*\))$/\1/p' |
  sed 's/:\*$//' |
  sed 's/ \*$//' |
  sort -u
)

if [ ${#ALLOWED_PREFIXES[@]} -eq 0 ]; then
  exit 0
fi

# セキュリティ上危険な環境変数（これらは常にプロンプト表示）
SENSITIVE_VAR_PREFIXES=(
  "PATH=" "LD_" "DYLD_" "PYTHONPATH=" "PYTHONHOME="
  "NODE_PATH=" "GEM_PATH=" "GEM_HOME=" "RUBYLIB="
  "PERL5LIB=" "CLASSPATH=" "GOPATH="
)

is_sensitive_var() {
  local assignment="$1"
  for prefix in "${SENSITIVE_VAR_PREFIXES[@]}"; do
    if [[ "$assignment" == "$prefix"* ]]; then
      return 0
    fi
  done
  return 1
}

# 環境変数を除去してから、コマンドが許可リストにマッチするか判定
matches_allowed() {
  local cmd="$1"
  cmd="$(echo "$cmd" | sed 's/^[[:space:]]*//')"

  while [[ "$cmd" =~ ^([A-Za-z_][A-Za-z0-9_]*=) ]]; do
    local assignment="${cmd%%[[:space:]]*}"
    if is_sensitive_var "$assignment"; then
      return 1  # 危険な環境変数 → 必ずプロンプト
    fi
    if [[ "$cmd" =~ ^[A-Za-z_][A-Za-z0-9_]*=\"[^\"]*\"[[:space:]]+(.*) ]]; then
      cmd="${BASH_REMATCH[1]}"
    elif [[ "$cmd" =~ ^[A-Za-z_][A-Za-z0-9_]*=\'[^\']*\'[[:space:]]+(.*) ]]; then
      cmd="${BASH_REMATCH[1]}"
    elif [[ "$cmd" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+(.*) ]]; then
      cmd="${BASH_REMATCH[1]}"
    else
      break
    fi
  done

  for prefix in "${ALLOWED_PREFIXES[@]}"; do
    if [[ "$cmd" == "$prefix" || "$cmd" == "$prefix "* ]]; then
      return 0
    fi
  done
  return 1
}

# ★ クォート対応のコマンド分割関数
# シングルクォート・ダブルクォートの中にいる間は |, &&, ; をスキップ
# これにより grep -E "foo|bar" の | を誤分割しない
split_stages() {
  local cmd="$1"
  local len=${#cmd}
  local i=0
  local sq=false    # シングルクォート内かどうか
  local dq=false    # ダブルクォート内かどうか
  local current=""
  while [ $i -lt $len ]; do
    local c="${cmd:$i:1}"
    local next="${cmd:$((i+1)):1}"
    # バックスラッシュエスケープ
    if [ "$c" = "\\" ] && ! $sq; then
      current+="$c$next"
      ((i+=2))
      continue
    fi
    # シングルクォートの開閉
    if [ "$c" = "'" ] && ! $dq; then
      if $sq; then sq=false; else sq=true; fi
      current+="$c"
      ((i += 1))
      continue
    fi
    # ダブルクォートの開閉
    if [ "$c" = '"' ] && ! $sq; then
      if $dq; then dq=false; else dq=true; fi
      current+="$c"
      ((i += 1))
      continue
    fi
    # クォートの外にいる場合のみ、演算子で分割
    if ! $sq && ! $dq; then
      if [ "$c" = "|" ]; then
        printf '%s\n' "$current"
        current=""
        ((i += 1))
        continue
      fi
      if [ "$c" = ";" ]; then
        printf '%s\n' "$current"
        current=""
        ((i += 1))
        continue
      fi
      if [ "$c" = "&" ] && [ "$next" = "&" ]; then
        printf '%s\n' "$current"
        current=""
        ((i+=2))
        continue
      fi
    fi
    current+="$c"
    ((i += 1))
  done
  [ -n "$current" ] && printf '%s\n' "$current"
}

# 分割して各ステージを判定
STAGES=()
while IFS= read -r seg; do
  [ -n "$seg" ] && STAGES+=("$seg")
done < <(split_stages "$COMMAND")

all_match=true
for stage in "${STAGES[@]}"; do
  stage="$(echo "$stage" | sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' \
    | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
  clean="$(echo "$stage" | sed 's/[0-9]*>&[0-9]*//g' \
    | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
  [ -z "$clean" ] && continue
  if ! matches_allowed "$clean"; then
    all_match=false
    break
  fi
done

if [ "$all_match" = true ]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: "All pipeline stages match allowed Bash prefixes"
    }
  }'
  exit 0
fi

exit 0
