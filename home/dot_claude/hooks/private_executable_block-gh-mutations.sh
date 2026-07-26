#!/usr/bin/env bash
# PreToolUse(Bash): 人間が判断すべき gh の不可逆/外向き操作を物理的にブロックする。
# PR の ready/merge/close/reopen・release の create/delete/edit/upload・
# repo の delete/archive/edit は影響が外部に及ぶため人間が判断・実行すること。
# 安全側設計: jq 無し / 空コマンドなら exit 0(通す)。read-only な gh は素通し。
#
# best-effort な抑止であり完全防御ではない。判定は heredoc 本文を除去 → 改行で行分割 →
# 各行を正規化 → BORDER + PRE + FLAGS の ERE、の順。
# 受容している素通り(実測済み):
#   - alias / シェル関数経由(例 g(){ gh "$@";}; g pr merge)と関数定義そのもの
#   - トークン内クォート分断(例 g"h" pr merge)
#   - `command` / `xargs` / `nohup` / `sudo` / `env` のラッパー経由
#   - `bash -c "gh ..."` / `sh -c '...'` / `eval "gh ..."`(gh の直前が `"` や `-c` になり
#     BORDER に当たらない。モデルがスクリプト化する時に自然に書く形)
#   - バッククォート起動(例 x=`gh pr merge 1`。`$(...)` は BORDER の `(` で捕捉する)
#   - `case x in a) gh ... ;; esac` の分岐本体(`)` は BORDER に含まれない)
#   - バックスラッシュ行継続(改行分割で2片に割れる)
#   - PRE のキーワードは列挙であり、列挙外の前置語は素通りする
#   - heredoc を stdin として実行する形(`bash <<EOF` / `cat <<EOF | bash` / `ssh h <<EOF`)。
#     本文は実行されるコマンドだが strip_heredocs はデータと区別せず落とす
# 意図的な過剰遮断(止めすぎ側。人間は Claude Code のプロンプトの ! バイパスで実行できる):
#   - 文字列リテラル内の `; then gh pr merge …`(BORDER + PRE に当たる)
#   - クォート内の実改行の後に行頭 gh が来る形(行ごとに判定するため)
#   - 終端タグが見つからない heredoc の本文(strip_heredocs が復帰させる。D-38)。
#     実シェルでも構文エラーになる形(未終端 / 終端行の末尾空白 / `<<-` 無しのインデント
#     終端)だけが該当する
# D-NN は外部脳の負債台帳の項番(GitHub issue 番号ではない)。
# あくまで「うっかり実行」の抑止(既存 hook 群と同じ性質)。
# トークン全体を囲むクォート(例 gh pr "merge" / "gh" pr merge)は normalized_words_of_segment
# の1段除去で捕捉する(2026-06。Knowledge/字句grep型hookはクォート付きフラグを取りこぼす)。
# 同様に短縮フラグ値連結(gh -Ro/r pr merge)や値2語フラグ越え(gh --foo a b pr
# merge)も字句検査で取りこぼしうる(FLAGS が想定する「フラグ + 値1個」の形から
# 外れるため)。これらも既知の限界として受容する。
# gh api(-X DELETE/PUT 等)も同等の破壊操作が可能だが、read-only な GET も含み
# 誤検知が多いため意図的に対象外とする(ユーザーと合意済みの判断)。
set -euo pipefail

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$LIB" ) >/dev/null 2>&1 || exit 0
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0
cmd="$(hook_command)"; [[ -z "$cmd" ]] && exit 0

source_hook_lib resolve-git-target.sh || exit 0

# gh はサブコマンドの前にグローバル/継承フラグを置ける(例 `gh -R o/r pr merge`、
# `gh --repo=o/r pr merge`)。gh とサブコマンドの間に「`-` 始まりのフラグトークン
# (+ 任意で続く非フラグの値1個)」だけを任意個許容してこの bypass を塞ぐ。
# 任意トークン貫通((\S+\s+)* 等)は && や他コマンド引数まで巻き込むので使わない。
FLAGS='(-{1,2}[A-Za-z][A-Za-z0-9-]*(=\S+)?\s+([^-\s]\S*\s+)?)*'

# gh の直前に置ける環境変数代入(例 `GH_TOKEN=x gh pr merge`、`PAGER=cat gh ...`)と、
# シェルキーワード(ループ・条件分岐・time 計測)を任意個・順不同で許容する。
# `VAR=val` は値に空白を含まない正規の POSIX 前置構文で、Claude が自然に書きうる
# (ページャ無効化やトークン指定)。キーワード側は BORDER が区切り文字の直後しか見ないため、
# 語が1つ挟まると3つの ERE が全て外れるのを塞ぐ。
# 順不同にするのは `GH_TOKEN=x time gh ...` と `time GH_TOKEN=x gh ...` の両方が書けるため。
# ERE の `{` は区間指定と衝突するので文字クラスで書く。
# キーワードは列挙であり、列挙外の前置語(env / sudo / case 分岐本体)は素通りする。
PRE='((do|then|else|elif|if|while|until|time|[{]|!)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=\S+[[:space:]]+)*'

# 前方は「コマンド開始位置の gh」に限定する: 行頭、または ; & | ( のコマンド区切り
# 直後(&& || | ( $( の境界を単一文字でカバー)+ 任意空白。これで文字列リテラルや
# コメント内の gh 言及を誤ブロックしない。末尾 END はサブコマンド名の直後の境界。
BORDER='(^|[;&|(])[[:space:]]*'
END='(\s|$|[;&|)])'

# 2026-06: 各行を normalized_words_of_segment で正規化(read -r -a でトークン化 → 各
# _strip_one_quote → 単一空白で再結合)してから旧 whole-cmd ERE を適用する。これで
# `gh pr "merge"` / `"gh" pr merge` のクォート付き素通り(Knowledge/字句grep型hookは
# クォート付きフラグを取りこぼす)を塞ぎつつ、ERE 判定の堅牢性を保つ。
# split_git_segments への作り替えは `FOO='a&b' gh pr merge` のように env 値内の `&;|` を
# クォート無視で誤分割し検出漏れを起こす(self-review R-1)。改行だけの分割はこの誤分割を
# 持ち込まないので、D-36(2行目以降が読まれない)はこちらで塞ぐ。
#
# heredoc 除去はどの版を使うかの選択ごと lib が単一情報源(strip_heredocs_block_side)。
# ラッパごと無い旧 lib のときだけ厳格版へ、それも無ければ除去を省く。
cmd="$(strip_heredocs_block_side "$cmd" 2>/dev/null || strip_heredocs "$cmd" 2>/dev/null || printf '%s' "$cmd")"

# normalized_words_of_segment は here-string の read が1行目で止まるため、行ごとに呼ぶ。
# 行ごとにコマンド置換が張られるので、`gh` を含まない行は正規化せず空行で置く(行数は保つ)。
# 正規化はトークン単位のクォート1段除去 + 空白再結合しかしないため、正規化後に語 `gh` が
# 現れる行は元の行にも部分文字列 `gh` を含む(`g"h"` のトークン内分断は元々受容済みの素通り)。
normalized=""
while IFS= read -r line; do
  case "$line" in
  *gh*) normalized="${normalized}$(normalized_words_of_segment "$line")"$'\n' ;;
  *) normalized="${normalized}"$'\n' ;;
  esac
done <<<"$cmd"

MSG_TAIL='人間が判断し、必要なら Claude Code のプロンプトで !<コマンド> として実行すること(Bash 引数の先頭に ! を付けても同じくブロックされる)。複数行コマンドは行ごとに判定するため、引数内の改行後に現れた語にも当たる。'

if printf '%s' "$normalized" | grep -qE "${BORDER}${PRE}gh\\s+${FLAGS}pr\\s+(ready|merge|close|reopen)${END}"; then
  echo "ブロック: gh pr の ready/merge/close/reopen は不可逆な PR 状態変更のため禁止。${MSG_TAIL}" >&2
  exit 2
fi

if printf '%s' "$normalized" | grep -qE "${BORDER}${PRE}gh\\s+${FLAGS}release\\s+(create|delete|edit|upload)${END}"; then
  echo "ブロック: gh release の create/delete/edit/upload は公開リリースを動かすため禁止。${MSG_TAIL}" >&2
  exit 2
fi

if printf '%s' "$normalized" | grep -qE "${BORDER}${PRE}gh\\s+${FLAGS}repo\\s+(delete|archive|edit)${END}"; then
  echo "ブロック: gh repo の delete/archive/edit は不可逆なリポ操作のため禁止。${MSG_TAIL}" >&2
  exit 2
fi

exit 0
