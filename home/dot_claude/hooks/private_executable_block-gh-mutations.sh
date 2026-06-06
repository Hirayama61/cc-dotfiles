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

# 2026-06: cmd 全体ではなくセグメント単位で判定する。split_git_segments で `&& || ; | &` を
# 境界に分割し、各セグメントを normalized_words_of_segment で quote 1段除去・正規化してから
# 既存 ERE を適用する。これで `gh pr "merge"` / `"gh" pr merge` のクォート付き素通り
# (Knowledge/字句grep型hookはクォート付きフラグを取りこぼす の層 (b)相当)を塞ぐ。
# 練られた FLAGS/ENV パターンはトークン照合への作り替えより退行リスクが低いので温存する。
# セグメント分割後は `;&|` が境界へ抜けるので BORDER は「セグメント先頭 / `(`($( 含む)直後」に
# 単純化。END もサブコマンド直後の境界(空白 / 末尾 / `)`)に単純化する。
BORDER='(^|[(])[[:space:]]*'
END='(\s|$|[)])'

gh_seg_matches() {
  local nseg="${1:-}" sub="${2:-}" verbs="${3:-}"
  echo "$nseg" | grep -qE "${BORDER}${ENV}gh\\s+${FLAGS}${sub}\\s+(${verbs})${END}"
}

while IFS= read -r seg; do
  [[ -z "$seg" ]] && continue
  nseg="$(normalized_words_of_segment "$seg")"

  if gh_seg_matches "$nseg" pr 'ready|merge|close|reopen'; then
    echo "ブロック: gh pr の ready/merge/close/reopen は不可逆な PR 状態変更のため禁止。人間が判断・実行すること。" >&2
    exit 2
  fi
  if gh_seg_matches "$nseg" release 'create|delete|edit|upload'; then
    echo "ブロック: gh release の create/delete/edit/upload は公開リリースを動かすため禁止。人間が判断・実行すること。" >&2
    exit 2
  fi
  if gh_seg_matches "$nseg" repo 'delete|archive|edit'; then
    echo "ブロック: gh repo の delete/archive/edit は不可逆なリポ操作のため禁止。人間が判断・実行すること。" >&2
    exit 2
  fi
done < <(split_git_segments "$cmd")

exit 0
