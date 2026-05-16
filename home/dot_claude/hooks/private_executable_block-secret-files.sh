#!/bin/bash
# block-secret-files.sh — PreToolUse hook (Read matcher)
#
# 秘密情報ファイルの読み込みをブロックする(Claude がコンテキストに
# 秘密を吸い込む事故を防ぐ)。出典: prior dotfiles。
#
# ブロック対象:
#   .env, .env.* / *.pem,*.key,*.p12,*.pfx / *.secret,*.secrets
#   id_rsa,id_ed25519,id_ecdsa,id_dsa / credentials,credentials.json,.netrc
#   *.token

set -euo pipefail

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
if [ -z "$FILE_PATH" ]; then
  exit 0
fi

BASENAME=$(basename "$FILE_PATH")

BLOCKED=false

if [[ "$BASENAME" == ".env" ]] || [[ "$BASENAME" == .env.* ]]; then
  BLOCKED=true
fi

if [[ "$BASENAME" == *.pem ]] || [[ "$BASENAME" == *.key ]] || \
   [[ "$BASENAME" == *.p12 ]] || [[ "$BASENAME" == *.pfx ]]; then
  BLOCKED=true
fi

if [[ "$BASENAME" == *.secret ]] || [[ "$BASENAME" == *.secrets ]]; then
  BLOCKED=true
fi

if [[ "$BASENAME" == "id_rsa" ]] || [[ "$BASENAME" == "id_ed25519" ]] || \
   [[ "$BASENAME" == "id_ecdsa" ]] || [[ "$BASENAME" == "id_dsa" ]]; then
  BLOCKED=true
fi

if [[ "$BASENAME" == "credentials" ]] || [[ "$BASENAME" == "credentials.json" ]] || \
   [[ "$BASENAME" == ".netrc" ]]; then
  BLOCKED=true
fi

if [[ "$BASENAME" == *.token ]]; then
  BLOCKED=true
fi

if [[ "$BLOCKED" == "true" ]]; then
  echo "BLOCKED: 秘密情報ファイルの読み込みをブロックしました: $FILE_PATH" >&2
  echo "必要な値だけを直接会話に貼り付けてください。" >&2
  exit 2
fi

exit 0
