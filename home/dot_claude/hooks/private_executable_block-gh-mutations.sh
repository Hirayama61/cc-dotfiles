#!/usr/bin/env bash
# PreToolUse(Bash): 人間が判断すべき gh の不可逆/外向き操作を物理的にブロックする。
# PR の ready/merge/close/reopen・release の create/delete/edit/upload・
# repo の delete/archive/edit は影響が外部に及ぶため人間が判断・実行すること。
# 安全側設計: jq 無し / 空コマンドなら exit 0(通す)。read-only な gh は素通し。
#
# best-effort な抑止であり完全防御ではない: alias / シェル関数 / トークン内クォート分断
# (例 g"h" pr merge)・変数置換(例 g(){ gh "$@";}; g pr merge)・`command gh` / `xargs gh`
# 等のラッパー経由・`{ gh ...; }` やバッククォートでの起動は grep の字句検査では原理的に
# 捕捉できない。あくまで「うっかり実行」の抑止(既存 hook 群と同じ性質)。
# トークン全体を囲むクォート(例 gh pr "merge" / "gh" pr merge)は normalized_words_of_segment
# の1段除去で捕捉する(2026-06。Knowledge/字句grep型hookはクォート付きフラグを取りこぼす)。
# 同様に短縮フラグ値連結(gh -Ro/r pr merge)や値2語フラグ越え(gh --foo a b pr
# merge)も字句検査で取りこぼしうる(FLAGS が想定する「フラグ + 値1個」の形から
# 外れるため)。これらも既知の限界として受容する。
# gh api(-X DELETE/PUT 等)も同等の破壊操作が可能だが、read-only な GET も含み
# 誤検知が多いため意図的に対象外とする(ユーザーと合意済みの判断)。
set -euo pipefail

command -v jq &>/dev/null || exit 0
input="$(cat)"
cmd="$(echo "$input" | jq -r '.tool_input.command // empty')"
[[ -z "$cmd" ]] && exit 0

LIB="$HOME/.claude/hooks/lib/resolve-git-target.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
. "$LIB"

# gh はサブコマンドの前にグローバル/継承フラグを置ける(例 `gh -R o/r pr merge`、
# `gh --repo=o/r pr merge`)。gh とサブコマンドの間に「`-` 始まりのフラグトークン
# (+ 任意で続く非フラグの値1個)」だけを任意個許容してこの bypass を塞ぐ。
# 任意トークン貫通((\S+\s+)* 等)は && や他コマンド引数まで巻き込むので使わない。
FLAGS='(-{1,2}[A-Za-z][A-Za-z0-9-]*(=\S+)?\s+([^-\s]\S*\s+)?)*'

# gh の直前に置ける環境変数代入(例 `GH_TOKEN=x gh pr merge`、`PAGER=cat gh ...`)も
# 任意個許容する。`VAR=val` は値に空白を含まない正規の POSIX 前置構文で、Claude が
# 自然に書きうる(ページャ無効化やトークン指定)ため BORDER の素通しを塞ぐ。
ENV='([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*'

# 前方は「コマンド開始位置の gh」に限定する: 行頭、または ; & | ( のコマンド区切り
# 直後(&& || | ( $( の境界を単一文字でカバー)+ 任意空白。これで文字列リテラルや
# コメント内の gh 言及を誤ブロックしない。末尾 END はサブコマンド名の直後の境界。
BORDER='(^|[;&|(])[[:space:]]*'
END='(\s|$|[;&|)])'

# 2026-06: cmd 全体を normalized_words_of_segment で正規化(read -r -a でトークン化 → 各
# _strip_one_quote → 単一空白で再結合)してから旧 whole-cmd ERE を適用する。これで
# `gh pr "merge"` / `"gh" pr merge` のクォート付き素通り(Knowledge/字句grep型hookは
# クォート付きフラグを取りこぼす)を塞ぎつつ、whole-cmd 判定の堅牢性を保つ。
# split_git_segments への作り替えは `FOO='a&b' gh pr merge` のように env 値内の `&;|` を
# クォート無視で誤分割し検出漏れを起こす(self-review R-1)。トークン化は env 値を1トークンに
# 保つので非分割でよい。練られた FLAGS/ENV パターンは温存する。
normalized="$(normalized_words_of_segment "$cmd")"

if echo "$normalized" | grep -qE "${BORDER}${ENV}gh\\s+${FLAGS}pr\\s+(ready|merge|close|reopen)${END}"; then
  echo "ブロック: gh pr の ready/merge/close/reopen は不可逆な PR 状態変更のため禁止。人間が判断・実行すること。" >&2
  exit 2
fi

if echo "$normalized" | grep -qE "${BORDER}${ENV}gh\\s+${FLAGS}release\\s+(create|delete|edit|upload)${END}"; then
  echo "ブロック: gh release の create/delete/edit/upload は公開リリースを動かすため禁止。人間が判断・実行すること。" >&2
  exit 2
fi

if echo "$normalized" | grep -qE "${BORDER}${ENV}gh\\s+${FLAGS}repo\\s+(delete|archive|edit)${END}"; then
  echo "ブロック: gh repo の delete/archive/edit は不可逆なリポ操作のため禁止。人間が判断・実行すること。" >&2
  exit 2
fi

exit 0
