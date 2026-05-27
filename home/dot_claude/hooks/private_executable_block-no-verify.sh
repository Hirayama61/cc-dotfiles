#!/usr/bin/env bash
# PreToolUse(Bash): git commit --no-verify / -n をブロックする。
# pre-commit フック(lint / format / secret スキャン等)のバイパスを防ぎ
# 品質ゲートを維持する。
#
# 判定は `git commit` を含むセグメントに限定する。コマンドをセグメント分割し、
# サブコマンドが commit のセグメント内だけで -n / --no-verify を探す。これにより
# `bash -n script && git commit -m x` や `grep -n foo && git commit -m x` の `-n` を
# git の no-verify と誤認する偽陽性を解消する(本日 PR #3 で実証)。
# 既知の限界: commit セグメント内のメッセージ本文に `-n`/`--no-verify` 様のトークンが
# あると誤ブロックしうる(例 `git commit -m '... -n ...'`)。完全な切り分けには引数パース
# (quote 復元)が要りリスクが高いため受容する。検知は best-effort(難読化は素通る)で
# あり敵対防御ではない。安全側: jq 無しなら exit 0。
set -euo pipefail

command -v jq &>/dev/null || exit 0
input="$(cat)"
cmd="$(echo "$input" | jq -r '.tool_input.command // empty')"
[[ -z "$cmd" ]] && exit 0

LIB="$HOME/.claude/hooks/lib/resolve-git-target.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
. "$LIB"

while IFS= read -r seg; do
  [[ -z "$seg" ]] && continue
  [[ "$(git_subcommand_of_segment "$seg")" == "commit" ]] || continue
  # commit セグメント内の no-verify。短縮形の集合 -n(`-anm` 等の連結含む)も捕捉する。
  # 単語境界は [[:space:]] / 行頭行末で表現(BSD grep 互換のため \b は使わない)。
  if echo "$seg" | grep -qE '(^|[[:space:]])--no-verify([[:space:]]|=|$)|(^|[[:space:]])-[a-mo-zA-Z]*n[a-zA-Z]*([[:space:]]|$)'; then
    echo "ブロック: --no-verify は pre-commit フックをバイパスするため禁止。コードを直してフックを通すこと。" >&2
    exit 2
  fi
done < <(split_git_segments "$cmd")

exit 0
