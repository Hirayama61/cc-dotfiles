#!/usr/bin/env bash
# code-resurrect-check.sh — 消失検知 Tier 2: 復活コードの機械的検知
# (参謀ゲート Phase 3。self-review skill のプリステップ専用)。
#
# Usage: code-resurrect-check.sh [<dir>]
#        code-resurrect-check.sh --triple <merge-base> <base-tip> <head> [<dir>]
#          (回顧検証ハーネス用。三点を明示して committed 範囲のみで判定する。
#           ハーネス本体は repo 同梱しない方針(PR #51 トリアージ)のため、実行記録は
#           PR 本文を参照)
#   env TIER2_WINDOW … base 側の削除を遡る first-parent コミット数(既定 200)
#
# 何をするか(三者比較):
#   merge-base(分岐点)・base-tip(保護祖先の現在)・HEAD/作業ツリー の三点で、
#   「base 側で削除されたままのコード行をブランチが再追加していないか」を検出する。
#   = レビュー等で base から消されたコードが、ブランチの(古い内容の Write 等による)
#   追加で復活している状態。
#
# 母数(base 側削除行)の定義 — 2026-06-11 の設計判断:
#   - 計画の字義「base が削除した行 ∧ HEAD が保持」の直実装は、分岐点に存在した行が
#     HEAD に自明に残るため「ブランチが遅れているだけ」で全件陽性になる。
#     復活事故の実体はブランチの**追加**側なので、照合相手はブランチ追加行に限定する。
#   - 削除の窓を mb..base-tip に限ると、本命シナリオ(分岐点より前の PR で削除済みの
#     コードを古い内容で再追加)を取りこぼす。また snapshot 間 net diff は
#     「追加→レビューで削除」を相殺して見落とす。そこで母数は
#     **base の first-parent 直近 TIER2_WINDOW コミットの per-commit 削除行のうち、
#     base-tip に現存しないもの**とする(base が後で正当に再追加した行は除外)。
#   - log は --first-parent --diff-merges=first-parent で取る: 保護ブランチの
#     タイムラインで「各 PR が base に与えた差分」を見る。これにより
#     (a) merge commit 経由の削除(conflict 解消含む)を取りこぼさない、
#     (b) topic ブランチ内部だけで追加→削除され base に一度も存在しなかった行を
#     母数に混ぜない。
#   - 削除候補の log はブランチ追加行の path 群に pathspec で限定する(意味論同値の
#     まま I/O を桁削減。path 数が多い時は無制限 log にフォールバック)。pathspec
#     指定時の -n は「当該 path に触れた first-parent コミット数」になり、実効窓は
#     無指定時より深くなる(検知側に有利な方向の差なので受容)。
#
# 行の照合は正規化(前後空白除去・連続空白の畳み込み)+ ノイズ除去
# (8 文字未満 / 英数字を含まない行は除外)した上で path+行 の完全一致。
#
# 出力契約(self-review skill が解釈する。**機械解釈は最終行のみ**):
#   TIER2-RESULT: RESURRECT files=<n> lines=<m>  … 復活あり → ack ゲート必須
#       (<m> は正規化後のユニーク行数。同一行の複数回出現は 1 と数える)
#   TIER2-RESULT: OK(<理由>) …                   … 復活なし
#   TIER2-RESULT: SKIP(<理由>) …                 … 判定不能。レビューは止めず
#                                                   この lens だけ skip(fail-open)
#   詳細行はその前に人間可読で出す(ファイル内容由来のテキストを含むため信頼しない。
#   制御文字は除去して出力する)。最終行はスクリプト自身が本文と独立に 1 回だけ出力する
#   (本文内容による偽装を構造的に排除)。exit code は常に 0。
#   優先順位: RESURRECT > SKIP > OK(判定不能を「復活なし」に折りたたまない)。
#
# 限界(best-effort で受容):
#   - proxy の限界: git は削除理由を知らない。レビュー由来でない base 削除
#     (リファクタ等)の再追加も拾いうる(誤検知率は実データ検証済み: merge 済み
#     PR 71 件で 0 件)。
#   - 助言的ゲートであり敵対防御ではない: 行を 1 トークン変える・別ファイルへ
#     復活させる・窓より古い削除を復活させる等で回避できる(既存 hook 群と同じ性質)。
#   - 照合は path 単位。別ファイルへの復活・rename を跨ぐ復活は拾えない。
#   - 行集合は unique 化して扱う。重複行の一方だけの削除(出現数の減少)は拾えない。
#   - 短い行・記号だけの行はノイズ除去で対象外(閉じ括弧の一致等を拾わない)。
#   - C-quote されるパス(引用符・制御文字・タブ等を含むファイル名)は解釈不能として
#     扱う: ブランチ追加側にあれば SKIP、base 削除側のみなら当該分を落として続行。
#   - untracked 新規ファイルは git diff に出ないため対象外(add 後に検知される)。
set -uo pipefail

mode="normal"
if [[ "${1:-}" == "--triple" ]]; then
  mode="triple"
  arg_mb="${2:-}"
  arg_base_tip="${3:-}"
  arg_head="${4:-}"
  dir="${5:-$PWD}"
else
  dir="${1:-$PWD}"
fi
window="${TIER2_WINDOW:-200}"

skip() {
  printf 'TIER2-RESULT: SKIP(%s)\n' "$1"
  exit 0
}
ok() {
  printf 'TIER2-RESULT: OK(%s)\n' "$1"
  exit 0
}

[[ "$window" =~ ^[1-9][0-9]*$ ]] || skip "TIER2_WINDOW 不正: $window"

LIB_DIR="$HOME/.claude/hooks/lib"
LIB="$LIB_DIR/resolve-base-ref.sh"
[[ -r "$LIB" ]] || skip "lib 不達: resolve-base-ref.sh"
# 構文破損 lib の直 source は bash が status 2 で即死するため subshell で先に検査
# shellcheck source=/dev/null
( . "$LIB" ) >/dev/null 2>&1 || skip "lib 破損: resolve-base-ref.sh"
# shellcheck source=/dev/null
. "$LIB" 2>/dev/null || skip "lib 読込失敗: resolve-base-ref.sh"
type resolve_base_ref >/dev/null 2>&1 || skip "lib 旧版: resolve_base_ref 未定義"

git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || skip "git repo 外: $dir"

if [[ "$mode" == "triple" ]]; then
  [[ -n "$arg_mb" && -n "$arg_base_tip" && -n "$arg_head" ]] || skip "--triple 引数不足(mb/base-tip/head)"
  mb="$arg_mb"
  base_tip="$arg_base_tip"
  head_ref="$arg_head"
  for r in "$mb" "$base_tip" "$head_ref"; do
    git -C "$dir" rev-parse --verify --quiet "$r^{commit}" >/dev/null 2>&1 || skip "ref 不正: $r"
  done
  base_label="$base_tip"
else
  base="$(resolve_base_ref "$dir")"
  [[ -z "$base" ]] && skip "base 解決不能(保護祖先なし)"
  mb="$(git -C "$dir" merge-base "$base" HEAD 2>/dev/null || true)"
  [[ -z "$mb" ]] && skip "merge-base 取得失敗(base=$base)"
  base_tip="$base"
  head_ref=""
  base_label="$base"
fi

printf 'TIER2: 復活コード検知(base=%s, merge-base=%s, window=%s)\n' "$base_label" \
  "$(git -C "$dir" rev-parse --short "$mb" 2>/dev/null || printf '%s' "$mb")" "$window"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/tier2.XXXXXX")" || skip "mktemp 失敗"
trap '[[ -n "$tmpdir" ]] && rm -rf "$tmpdir"' EXIT

# diff 出力形式を利用者設定から隔離する(diff.noprefix / external diff / textconv が
# a/ b/ 前提のパス解析を壊すのを防ぐ)。
GIT_DIFF=(git -c core.quotePath=false -c diff.noprefix=false -c diff.mnemonicPrefix=false -C "$dir")
DIFF_OPTS=(--no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/)

# 正規化・ノイズ除去の規則は抽出側(extract_lines)と base-tip 現存判定側で
# 完全一致が必要(ずれると照合が静かに壊れる)ため、awk プログラム片を共有する。
AWK_NORM='
  function norm(s) {
    gsub(/[ \t]+/, " ", s)
    sub(/^ /, "", s); sub(/ $/, "", s)
    return s
  }
  function keep(s) { return (length(s) >= 8 && s ~ /[A-Za-z0-9]/) }
'

# unified diff から「path<TAB>正規化行」を抽出する。
#   which=del → '-' 行(削除。path は --- a/ 側)
#   which=add → '+' 行(追加。path は +++ b/ 側)
# 行頭 '---'/'+++' とハンク内コンテンツの衝突は `diff --git` 起点のヘッダ状態機械で
# 区別する(ヘッダ捕捉中のみ ---/+++ をパスとして解釈)。
extract_lines() { # which <- stdin(diff)
  awk -v which="$1" "$AWK_NORM"'
    function emit(path, s) {
      n = norm(s)
      if (!keep(n)) return
      if (path == "/dev/null" || path == "") return
      print path "\t" n
    }
    /^diff --git / { hdr = 1; next }
    hdr == 1 && /^--- / { apath = substr($0, 5); sub(/^a\//, "", apath); hdr = 2; next }
    hdr == 2 && /^\+\+\+ / { bpath = substr($0, 5); sub(/^b\//, "", bpath); hdr = 0; next }
    hdr > 0 { next }
    /^-/ { if (which == "del") emit(apath, substr($0, 2)); next }
    /^\+/ { if (which == "add") emit(bpath, substr($0, 2)); next }
  ' | LC_ALL=C sort -u
}

# 1) ブランチ側が追加した行。normal は作業ツリー込み(未コミットも拾う)、
#    triple は committed 範囲(回顧検証で作業ツリーが無いため)。
if [[ "$mode" == "triple" ]]; then
  "${GIT_DIFF[@]}" diff "${DIFF_OPTS[@]}" "$mb..$head_ref" -- >"$tmpdir/branch.diff" 2>/dev/null || skip "branch 側 diff 取得失敗"
else
  "${GIT_DIFF[@]}" diff "${DIFF_OPTS[@]}" "$mb" -- >"$tmpdir/branch.diff" 2>/dev/null || skip "branch 側 diff 取得失敗"
fi
extract_lines add <"$tmpdir/branch.diff" >"$tmpdir/add.txt" || skip "追加行の抽出失敗"
[[ -s "$tmpdir/add.txt" ]] || ok "ブランチ側に追加行なし"

# C-quote されたパス(先頭 ")は a/ b/ 剥がしが効かず照合不能。ブランチ追加側に
# あれば判定不能として SKIP に倒す(細工ファイル名での無音バイパス防止)。
if cut -f1 "$tmpdir/add.txt" | grep -q '^"'; then
  skip "ブランチ追加側に解釈不能なパス(C-quote)あり"
fi

# 2) base 側の削除候補: first-parent 直近 window コミットの per-commit 削除行。
#    pathspec をブランチ追加行の path 群に限定して I/O を抑える(意味論同値)。
#    --pretty=format: はコミットメッセージ中の '-' 行の誤読防止。
path_args=()
path_count=0
while IFS= read -r p; do
  path_args+=(":(top)$p")
  path_count=$((path_count + 1))
done < <(cut -f1 "$tmpdir/add.txt" | LC_ALL=C sort -u)
if [[ "$path_count" -gt 500 ]]; then
  path_args=()
fi
if ! "${GIT_DIFF[@]}" log -p --first-parent --diff-merges=first-parent \
  --pretty=format: "${DIFF_OPTS[@]}" -n "$window" "$base_tip" -- ${path_args[@]+"${path_args[@]}"} \
  >"$tmpdir/base.log" 2>/dev/null; then
  skip "base 側 log 取得失敗"
fi
extract_lines del <"$tmpdir/base.log" >"$tmpdir/del_raw.txt" || skip "削除行の抽出失敗"
# base 削除側の C-quote パスは当該分だけ落として続行する(母数の部分欠落として明示)。
grep -v '^"' "$tmpdir/del_raw.txt" >"$tmpdir/del.txt" || true
dropped=$(($(wc -l <"$tmpdir/del_raw.txt") - $(wc -l <"$tmpdir/del.txt")))
[[ "$dropped" -gt 0 ]] && printf 'note: base 削除側の解釈不能パス %d 行を母数から除外\n' "$dropped"

# 3) 一次交差(path+行 の完全一致)。
LC_ALL=C comm -12 "$tmpdir/del.txt" "$tmpdir/add.txt" >"$tmpdir/cand.txt" 2>/dev/null || skip "照合失敗"
[[ -s "$tmpdir/cand.txt" ]] || ok "復活コードなし"

# 4) base-tip に現存する行を除外する(base が後で正当に再追加した行・
#    ブランチが base の現状と同じ内容を取り込んだだけの行は復活ではない)。
#    path は awk -v だと \t 等がエスケープ再解釈されるため ENVIRON で渡す。
: >"$tmpdir/hits.txt"
cut -f1 "$tmpdir/cand.txt" | LC_ALL=C sort -u | while IFS= read -r path; do
  git -C "$dir" show "$base_tip:$path" 2>/dev/null |
    awk "$AWK_NORM"'{ s = norm($0); if (keep(s)) print s }' |
    LC_ALL=C sort -u >"$tmpdir/present.txt" || : >"$tmpdir/present.txt"
  CAND_PATH="$path" awk -F'\t' '$1 == ENVIRON["CAND_PATH"] { print $2 }' "$tmpdir/cand.txt" |
    LC_ALL=C sort -u >"$tmpdir/cand_path.txt"
  LC_ALL=C comm -23 "$tmpdir/cand_path.txt" "$tmpdir/present.txt" 2>/dev/null |
    while IFS= read -r line; do
      [[ -n "$line" ]] && printf '%s\t%s\n' "$path" "$line" >>"$tmpdir/hits.txt"
    done
done

[[ -s "$tmpdir/hits.txt" ]] || ok "復活コードなし"

# 報告: path ごとに件数とサンプル(最大5行)を出す。制御文字は偽装対策で除去。
# 最終行(機械解釈の対象)は本文 awk と独立にスクリプトが出力する。
awk -F'\t' '
  {
    cnt[$1]++
    if (cnt[$1] <= 5) sample[$1] = sample[$1] "  復活行: " $2 "\n"
  }
  END {
    for (p in cnt) {
      printf "file: %s(%d 行)\n%s", p, cnt[p], sample[p]
      if (cnt[p] > 5) printf "  …他 %d 行\n", cnt[p] - 5
    }
  }
' "$tmpdir/hits.txt" | tr -d '\000-\010\013-\037\177'
n_files="$(cut -f1 "$tmpdir/hits.txt" | LC_ALL=C sort -u | wc -l | tr -d '[:space:]')"
n_lines="$(wc -l <"$tmpdir/hits.txt" | tr -d '[:space:]')"
printf 'TIER2-RESULT: RESURRECT files=%s lines=%s\n' "$n_files" "$n_lines"
exit 0
