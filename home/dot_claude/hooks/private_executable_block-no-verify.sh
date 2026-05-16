#!/usr/bin/env bash
# PreToolUse(Bash): git commit --no-verify / -n をブロックする。
# pre-commit フック(lint / format / secret スキャン等)のバイパスを防ぎ
# 品質ゲートを維持する。安全側設計: jq 無しなら exit 0。
set -euo pipefail

command -v jq &>/dev/null || exit 0
input="$(cat)"
cmd="$(echo "$input" | jq -r '.tool_input.command // empty')"
[[ -z "$cmd" ]] && exit 0

if echo "$cmd" | grep -qE '\bgit\s+commit\b' && \
   echo "$cmd" | grep -qE '(^|\s)--no-verify(\s|$)|(^|\s)-[a-mo-zA-Z]*n[a-zA-Z]*(\s|$)'; then
  echo "ブロック: --no-verify は pre-commit フックをバイパスするため禁止。コードを直してフックを通すこと。" >&2
  exit 2
fi

exit 0
