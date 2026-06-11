#!/usr/bin/env bash
# test-vanish-check.sh — 消失検知 Tier 1: 消えたテスト観点の機械的カウント
# (参謀ゲート Phase 2。self-review skill のプリステップ専用)。
#
# Usage: test-vanish-check.sh [<dir>]   (省略時 $PWD。レビュー対象 repo 内で呼ぶ)
#
# 何をするか:
#   1. base を「最近接の保護祖先」(resolve-base-ref.sh)で解決し、merge-base を取る。
#   2. merge-base → 作業ツリーの diff からテストファイル(test-patterns.sh の判定)を抽出。
#      作業ツリー比較なので未コミット変更も拾う(self-review の対象 = 未 push commit
#      + 作業ツリー、と一致)。rename は -M で追跡し、改名を消失と誤検知しない。
#      ただしテスト命名から外れる rename(*.test.ts → *.ts)はスイートからの消失
#      とみなし新側 0 カウントで扱う。
#   3. ファイルごとに case(it/test/describe + .only/.skip 等の modifier)と
#      assert(expect/assert 直呼び・メソッド・チェーン)の出現数を新旧で数え、
#      カウント減少 **または** 消えた title(best-effort 抽出の集合差)があれば
#      報告する。title 比較を併用するのは「1 件削除 + 1 件追加」の相殺で
#      カウントが沈黙するケースを拾うため。
#
# 出力契約(self-review skill が解釈する。**機械解釈は最終行のみ**):
#   TIER1-RESULT: DECREASE files=<n> cases=<±n> asserts=<±n>  … 減少あり → ack ゲート必須
#       (±n は「減少のあったファイルだけ」の新-旧合計。全体の純増減ではない)
#   TIER1-RESULT: OK …                                        … 減少なし
#   TIER1-RESULT: SKIP(<理由>) …                              … 判定不能。レビューは止めず
#                                                                この lens だけ skip(fail-open)
#   詳細行はその前に人間可読で出す(ファイル内容由来のテキストを含むため信頼しない。
#   制御文字は除去して出力する)。exit code は常に 0(判定は出力で伝える)。
#   優先順位: DECREASE > SKIP(計数不能ファイルあり)> OK。「判定できなかった」を
#   「減少なし」に折りたたまない。
#
# 限界(best-effort で受容):
#   - カウントは字句 grep。コメント内・文字列内のキーワードも数える(新旧同条件なので
#     増減判定への影響は小さい)。
#   - title 抽出は1行内の静的文字列のみ(テンプレート/動的生成・test.each は拾えない)。
#   - title の改名(typo 修正等)も「消えた title」として報告する(保守側に倒す。
#     ack で「改名」と答えれば通る)。
#   - パスにタブ・改行・引用符を含むファイルは計数不能として SKIP 側へ倒す
#     (core.quotePath=false で非 ASCII は素通しにした上で、残る C-quote を検出する)。
#   - 言語は JS/TS 先行。パターンは test-patterns.sh に集約してあり、そこへの追加で拡張する。
set -uo pipefail

dir="${1:-$PWD}"

skip() {
  printf 'TIER1-RESULT: SKIP(%s)\n' "$1"
  exit 0
}

LIB_DIR="$HOME/.claude/hooks/lib"
for lib in resolve-base-ref.sh test-patterns.sh; do
  [[ -r "$LIB_DIR/$lib" ]] || skip "lib 不達: $lib"
  # 構文破損 lib の直 source は bash が status 2 で即死するため subshell で先に検査
  # shellcheck source=/dev/null
  ( . "$LIB_DIR/$lib" ) >/dev/null 2>&1 || skip "lib 破損: $lib"
  # shellcheck source=/dev/null
  . "$LIB_DIR/$lib" 2>/dev/null || skip "lib 読込失敗: $lib"
done

# lib が旧版(apply 前後の skew)だと関数不在のまま両側 0 カウント → 偽 OK になる。
# 依存関数の存在を検査して SKIP に倒す(ドッグフーディングで実証した実バグ)。
for fn in resolve_base_ref test_file_ere test_case_ere test_assert_ere; do
  type "$fn" >/dev/null 2>&1 || skip "lib 旧版: $fn 未定義(mise run apply を確認)"
done

git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || skip "git repo 外: $dir"
# diff の出力パスは repo ルート相対。サブディレクトリ起動でも内容読出が壊れないよう
# ルートを解決して結合に使う。
root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$root" ]] && skip "toplevel 解決失敗"

base="$(resolve_base_ref "$dir")"
[[ -z "$base" ]] && skip "base 解決不能(保護祖先なし)"
mb="$(git -C "$dir" merge-base "$base" HEAD 2>/dev/null || true)"
[[ -z "$mb" ]] && skip "merge-base 取得失敗(base=$base)"

file_ere="$(test_file_ere)"
case_ere="$(test_case_ere)"
assert_ere="$(test_assert_ere)"

# ERE が壊れていると grep が常に rc>=2 → 両側 0 件の偽 OK になるため先に検証する
# (rc 0/1 = パターン正常、rc>=2 = パターン不正)。
for ere in "$file_ere" "$case_ere" "$assert_ere"; do
  printf 'x' | grep -E "$ere" >/dev/null 2>&1
  [[ $? -ge 2 ]] && skip "ERE 検証失敗(lib 破損疑い)"
done

count_matches() { # ere <- stdin
  local n
  n="$(grep -E -o "$1" 2>/dev/null | wc -l | tr -d '[:space:]')"
  printf '%s' "${n:-0}"
}

# it/test/describe の静的 title を1行1件で返す(quote 3種対応・best-effort)。
# 制御文字はレポート偽装(CR での行上書き等)を防ぐため除去する。
extract_titles() {
  grep -E -o "\b(it|test|describe)(\.[A-Za-z_]+)?[[:space:]]*\([[:space:]]*(\"[^\"]+\"|'[^']+'|\`[^\`]+\`)" 2>/dev/null |
    sed -E "s/^(it|test|describe)(\.[A-Za-z_]+)?[[:space:]]*\(([[:space:]])*//; s/^[\"'\`]//; s/[\"'\`]$//" |
    tr -d '\000-\010\013-\037\177' |
    sort
}

sanitize() { tr -d '\000-\010\013-\037\177'; }

printf 'TIER1: 消失検知(base=%s, merge-base=%s)\n' "$base" "$(git -C "$dir" rev-parse --short "$mb" 2>/dev/null || printf '%s' "$mb")"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/tier1.XXXXXX")" || skip "mktemp 失敗"
trap '[[ -n "$tmpdir" ]] && rm -rf "$tmpdir"' EXIT

# diff の失敗を偽 OK に折りたたまないよう、一旦ファイルへ取り rc を検査する。
# core.quotePath=false で非 ASCII パスの C-quote を抑止(quote されたパスは
# git show / -f 判定が失敗し無音の 0→0 = 偽 OK になる)。
if ! git -c core.quotePath=false -C "$dir" diff --name-status -M "$mb" -- >"$tmpdir/diff.txt" 2>/dev/null; then
  skip "diff 取得失敗(merge-base=$mb)"
fi

total_files=0
total_case_delta=0
total_assert_delta=0
decrease=0
uncountable=0

# -z(NUL 区切り)は bash 3.2 + BSD の read -d '' と相性が悪いので、タブ区切りの
# name-status 行を IFS で割る。quotePath=false 後も残る C-quote(引用符・制御文字
# 入りパス)は計数不能として SKIP 側へ倒す(無音の偽 OK にしない)。
while IFS=$'\t' read -r status p1 p2; do
  [[ -z "${status:-}" ]] && continue
  old_path="" new_path=""
  case "$status" in
  R*) old_path="$p1"; new_path="$p2" ;;
  D) old_path="$p1"; new_path="" ;;
  A) old_path=""; new_path="$p1" ;;
  *) old_path="$p1"; new_path="$p1" ;;
  esac
  # 新旧どちらかがテストファイルなら対象。diff のパスはルート相対(先頭スラッシュ
  # なし)なので、`/tests?/` がルート直下の tests/ に当たるよう '/' を前置して照合する。
  printf '/%s\n/%s\n' "$old_path" "$new_path" | grep -qE "$file_ere" || continue

  # C-quote されたパス(引用符始まり)は内容を読めない。無音で 0→0 に倒すと
  # テスト削除の偽 OK になるため計数不能として数える。
  if [[ "$old_path" == \"* || "$new_path" == \"* ]]; then
    uncountable=$((uncountable + 1))
    printf 'file: %s(計数不能: 特殊文字パス)\n' "$(printf '%s' "${new_path:-$old_path}" | sanitize)"
    continue
  fi

  old_content=""
  if [[ -n "$old_path" ]]; then
    if ! old_content="$(git -C "$dir" show "$mb:$old_path" 2>/dev/null)"; then
      # 旧 blob があるはずの経路(M/R/D)での取得失敗は計数不能(0 件と同一視しない)
      uncountable=$((uncountable + 1))
      printf 'file: %s(計数不能: 旧内容取得失敗)\n' "$(printf '%s' "$old_path" | sanitize)"
      continue
    fi
  fi
  new_content=""
  [[ -n "$new_path" && -f "$root/$new_path" ]] && new_content="$(cat "$root/$new_path" 2>/dev/null || true)"

  oc="$(printf '%s' "$old_content" | count_matches "$case_ere")"
  oa="$(printf '%s' "$old_content" | count_matches "$assert_ere")"
  rename_out=0
  if [[ -n "$new_path" ]] && ! printf '/%s\n' "$new_path" | grep -qE "$file_ere"; then
    # テスト命名から外れる rename はランナーの discovery から消える = スイートからの
    # 消失。内容が残っていても新側 0 カウントで扱う。
    rename_out=1
    nc=0; na=0
  else
    nc="$(printf '%s' "$new_content" | count_matches "$case_ere")"
    na="$(printf '%s' "$new_content" | count_matches "$assert_ere")"
  fi

  # title 集合は常に比較する。カウントだけだと「1 件削除 + 1 件追加」の相殺で
  # 沈黙する(検証 V17b で実証)ため、消えた title があればカウント同値でも報告する。
  printf '%s' "$old_content" | extract_titles >"$tmpdir/old.txt"
  if [[ "$rename_out" -eq 1 ]]; then
    : >"$tmpdir/new.txt"
  else
    printf '%s' "$new_content" | extract_titles >"$tmpdir/new.txt"
  fi
  removed_titles="$(comm -23 "$tmpdir/old.txt" "$tmpdir/new.txt" 2>/dev/null || true)"

  if [[ "$nc" -lt "$oc" || "$na" -lt "$oa" || -n "$removed_titles" ]]; then
    decrease=1
    total_files=$((total_files + 1))
    total_case_delta=$((total_case_delta + nc - oc))
    total_assert_delta=$((total_assert_delta + na - oa))
    label="${new_path:-$old_path}"
    [[ "$status" == R* ]] && label="$old_path -> $new_path"
    [[ "$status" == "D" ]] && label="$old_path(ファイル削除)"
    [[ "$rename_out" -eq 1 ]] && label="$label(テスト命名から離脱)"
    printf 'file: %s cases %s->%s asserts %s->%s\n' "$(printf '%s' "$label" | sanitize)" "$oc" "$nc" "$oa" "$na"
    printf '%s\n' "$removed_titles" | while IFS= read -r t; do
      [[ -n "$t" ]] && printf '  消えた title: "%s"\n' "$t"
    done
  fi
done <"$tmpdir/diff.txt"

if [[ "$decrease" -eq 1 ]]; then
  printf 'TIER1-RESULT: DECREASE files=%s cases=%s asserts=%s\n' \
    "$total_files" "$total_case_delta" "$total_assert_delta"
elif [[ "$uncountable" -gt 0 ]]; then
  skip "計数不能ファイル ${uncountable} 件(詳細行参照)"
else
  printf 'TIER1-RESULT: OK(テスト観点の減少なし)\n'
fi
exit 0
