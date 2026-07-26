#!/bin/bash
# block-secret-files.sh — PreToolUse hook (Read matcher)
#
# 秘密情報ファイルの読み込みをブロックする(Claude がコンテキストに
# 秘密を吸い込む事故を防ぐ)。
#
# 判定は basename を小文字化してから行う(拡張子の大小に依存しない)。
#
# ブロック対象:
#   .env, .env.* / *.pem,*.key,*.p12,*.pfx / *.secret,*.secrets / *.jks,*.keystore
#   id_rsa*,id_ed25519*,id_ecdsa*,id_dsa*(*.pub は除外)
#   credentials,.credentials と (.)credentials.<json|yml|yaml|txt|ini|cfg|conf|enc|plist>
#   .netrc,.envrc,.git-credentials,.npmrc,.pypirc,.pgpass / *.token
#   *service-account*.json,*service_account*.json
#
# 受容している素通り:
#   - credentials_prod.json のような前方一致の派生名(credentials.ts 等の普通のソース名を
#     Read 遮断しないことを優先し、前方一致にしていない)
#   - Read 以外の経路。この hook は Read matcher にしか登録していないので、Bash 経由
#     (cat .envrc 等)や Grep の出力からは同じ内容が読める。Bash 側の対になる遮断は無い
#   - 判定は basename のみなので、symlink や別名コピー経由は素通りする
#     (/proj/config.json → ~/.aws/credentials の symlink を Read すると通る)
#
# 意図的に過剰遮断側へ倒しているもの(いずれも人間の決定。バグと読んで緩めないこと):
#   - .env.example / .env.sample … `.env.*` に当たる。慣習的にコミットされる非秘密ファイル
#     だが、実際の秘密が入った .env.<環境名> と機械的に区別できない
#   - .envrc / .npmrc … 非秘密の運用(use flake だけ / registry 指定だけ)も普通にあるが、
#     direnv 経由のトークン export と npm の _authToken を機械的に区別できない
# 読みたい時は人間が ! プレフィックスで実行する。

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')
if [ -z "$FILE_PATH" ]; then
  exit 0
fi

BASENAME=$(basename "$FILE_PATH")
# bash 3.2 に ${var,,} が無いため tr。LC_ALL=C はロケール依存の大小変換を避ける。
LOWER=$(printf '%s' "$BASENAME" | LC_ALL=C tr '[:upper:]' '[:lower:]')

BLOCKED=false

if [[ "$LOWER" == ".env" ]] || [[ "$LOWER" == .env.* ]]; then
  BLOCKED=true
fi

if [[ "$LOWER" == *.pem ]] || [[ "$LOWER" == *.key ]] || \
   [[ "$LOWER" == *.p12 ]] || [[ "$LOWER" == *.pfx ]]; then
  BLOCKED=true
fi

if [[ "$LOWER" == *.secret ]] || [[ "$LOWER" == *.secrets ]]; then
  BLOCKED=true
fi

if [[ "$LOWER" == *.jks ]] || [[ "$LOWER" == *.keystore ]]; then
  BLOCKED=true
fi

# .pub 除外は id_* の内側だけに置く。グローバルな早期 exit にすると .env.pub のような
# 「他の判定に当たる名前 + .pub」まで通す抜け穴になる。
case "$LOWER" in
id_rsa* | id_ed25519* | id_ecdsa* | id_dsa*)
  case "$LOWER" in
  *.pub) : ;;
  *) BLOCKED=true ;;
  esac
  ;;
esac

# credentials は前方一致にしない(credentials.ts のような普通のソース名まで Read 遮断する)。
# 完全一致 + 既知の設定拡張子に限定する。credentials_prod.json 等の派生名は素通りする(受容)。
case "$LOWER" in
credentials | .credentials)
  BLOCKED=true
  ;;
credentials.json | credentials.yml | credentials.yaml | credentials.txt | \
  credentials.ini | credentials.cfg | credentials.conf | credentials.enc | credentials.plist | \
  credentials.yml.enc | credentials.yaml.enc | credentials.json.enc | \
  .credentials.json | .credentials.yml | .credentials.yaml | .credentials.txt | \
  .credentials.ini | .credentials.cfg | .credentials.conf | .credentials.enc | .credentials.plist | \
  .credentials.yml.enc | .credentials.yaml.enc | .credentials.json.enc)
  BLOCKED=true
  ;;
esac

if [[ "$LOWER" == ".netrc" ]] || [[ "$LOWER" == ".envrc" ]] || \
   [[ "$LOWER" == ".git-credentials" ]] || [[ "$LOWER" == ".npmrc" ]] || \
   [[ "$LOWER" == ".pypirc" ]] || [[ "$LOWER" == ".pgpass" ]]; then
  BLOCKED=true
fi

# GCP のダウンロード名は <project>-service-account.json、Python/Airflow 系の慣用名は
# service_account.json。前後の修飾を許して両表記を拾う(中身は生の秘密鍵)。
# 過剰遮断は受容する: service-account-schema.json のような非秘密の JSON も止まる。
if [[ "$LOWER" == *service-account*.json ]] || [[ "$LOWER" == *service_account*.json ]]; then
  BLOCKED=true
fi

if [[ "$LOWER" == *.token ]]; then
  BLOCKED=true
fi

if [[ "$BLOCKED" == "true" ]]; then
  echo "BLOCKED: 秘密情報ファイルの読み込みをブロックしました: $FILE_PATH" >&2
  echo "必要な値だけを直接会話に貼り付けてください。" >&2
  exit 2
fi

exit 0
