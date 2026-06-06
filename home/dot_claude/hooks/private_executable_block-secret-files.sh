#!/usr/bin/env bash
# block-secret-files.sh — PreToolUse hook (Read matcher)
#
# 秘密情報ファイルの読み込みをブロックする(Claude がコンテキストに
# 秘密を吸い込む事故を防ぐ)。
#
# ブロック対象:
#   .env, .env.* / *.pem,*.key,*.p12,*.pfx / *.secret,*.secrets
#   id_rsa,id_ed25519,id_ecdsa,id_dsa / credentials,credentials.json,.netrc
#   *.token
# 拡張子判定は大文字小文字を無視する(SERVER.PEM 等を取りこぼさない)。
# .env.example / .sample / .template / .dist 等のテンプレートは秘密を含まないので除外する。

set -euo pipefail

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
if [ -z "$FILE_PATH" ]; then
  exit 0
fi

BASENAME=$(basename "$FILE_PATH")

# 拡張子の大文字小文字差(SERVER.PEM / KEY.Pem)を吸収するため小文字化したコピーで判定する。
# tr 不在環境はまず無いが、無ければ原文のまま(従来挙動)にフォールバックする。
if command -v tr >/dev/null 2>&1; then
  LC_BASENAME=$(printf '%s' "$BASENAME" | tr '[:upper:]' '[:lower:]')
else
  LC_BASENAME=$BASENAME
fi

# テンプレート(秘密を含まない)は読取の正当ケースなので除外する。.env.example だけでなく
# *.example / *.sample / *.template / *.dist を一律に除外する。
case "$LC_BASENAME" in
*.example | *.sample | *.template | *.dist)
  exit 0
  ;;
esac

BLOCKED=false

if [[ "$LC_BASENAME" == ".env" ]] || [[ "$LC_BASENAME" == .env.* ]]; then
  BLOCKED=true
fi

if [[ "$LC_BASENAME" == *.pem ]] || [[ "$LC_BASENAME" == *.key ]] || \
   [[ "$LC_BASENAME" == *.p12 ]] || [[ "$LC_BASENAME" == *.pfx ]]; then
  BLOCKED=true
fi

if [[ "$LC_BASENAME" == *.secret ]] || [[ "$LC_BASENAME" == *.secrets ]]; then
  BLOCKED=true
fi

if [[ "$LC_BASENAME" == "id_rsa" ]] || [[ "$LC_BASENAME" == "id_ed25519" ]] || \
   [[ "$LC_BASENAME" == "id_ecdsa" ]] || [[ "$LC_BASENAME" == "id_dsa" ]]; then
  BLOCKED=true
fi

if [[ "$LC_BASENAME" == "credentials" ]] || [[ "$LC_BASENAME" == "credentials.json" ]] || \
   [[ "$LC_BASENAME" == ".netrc" ]]; then
  BLOCKED=true
fi

if [[ "$LC_BASENAME" == *.token ]]; then
  BLOCKED=true
fi

if [[ "$BLOCKED" == "true" ]]; then
  echo "BLOCKED: 秘密情報ファイルの読み込みをブロックしました: $FILE_PATH" >&2
  echo "必要な値だけを直接会話に貼り付けてください。" >&2
  exit 2
fi

exit 0
