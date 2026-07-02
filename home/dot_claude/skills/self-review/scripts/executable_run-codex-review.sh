#!/usr/bin/env bash
# run-codex-review.sh — self-review skill 手順 2 の Codex CLI レビュー起動を移設。
#
# Usage: run-codex-review.sh <base_ref>
#   レビュー対象 repo 内($PWD)で呼ばれる前提。base_ref は skill 手順 1 で決めた base ref。
#
# 別モデル(Codex CLI)の目を毎回並列参加させる。skill/Agent を経由せず CLI を直叩きする
# (名前衝突を避けるため CLI 固定)。diff を stdin・指示を引数で渡す(`codex exec` は両方を
# 同時に受け、stdin が piped かつ PROMPT 引数ありのとき stdin を `<stdin>` ブロックとして
# 指示に追記する。`-` は付けない=`-` は stdin 全体を PROMPT として読む別用途)。heredoc を
# 使わないのは markdown リスト内インデントで終端が壊れる罠を避けるため(呼び出し元 SKILL の
# 事情。ここでは素の文字列引数)。出力をキャプチャするのは exit 0 でも空応答(認証/レート
# 制限/ネットワーク起因で本文が返らない)を skip 扱いにするため(`||` だけでは exit 0 の
# 空応答を拾えない)。未導入・実行失敗・空応答とも `Codex: skip(理由)` と明示して続行し、
# レビューをブロックしない(常に exit 0)。コンテキスト隔離の原則どおり diff のみ渡し、
# 実装意図は与えない。
set -uo pipefail

base_ref="${1-}"
if [ -z "$base_ref" ]; then
  echo "Codex: skip(base_ref 未指定)"
  exit 0
fi

if command -v codex >/dev/null 2>&1; then
  codex_out="$(git diff "${base_ref}...HEAD" \
    | codex exec --sandbox read-only \
        "次の git diff をコードレビューせよ。実装意図は与えない。重大/改善/情報の3段階で、各指摘にファイル:行と理由を付けて出力せよ。" 2>/dev/null)"
  if [ -n "$codex_out" ]; then
    printf '%s\n' "$codex_out"
  else
    echo "Codex: skip(空応答 — 未認証/レート制限/ネットワーク疑い)"
  fi
else
  echo "Codex: skip(未導入)"
fi
exit 0
