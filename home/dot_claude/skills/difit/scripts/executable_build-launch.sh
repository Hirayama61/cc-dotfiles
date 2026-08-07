#!/usr/bin/env bash
# build-launch.sh — difit skill 手順 1: 見せる range を決めて difit の起動コマンドを組み立てる。
#
# Usage: build-launch.sh <repo> [<mode>] [<target> [<base>]]
#   repo   … 対象 repo の絶対パス(必須・非空)。`git -C ""` は rc=0 で cwd に
#            フォールバックするので、空文字は cwd の別リポを黙って対象にしてしまう。
#   mode   … auto(既定) | worktree | branch | commit
#   target/base … 人間が明示した rev。base を渡すと branch 形(二点差分を
#            --merge-base で三点にする)、target だけなら commit 形(`<rev>^..<rev>`)。
#
# 状態判定・base 解決・rev 検証・untracked 一覧の採取をここで完結させる。シェル変数は
# Bash 呼び出しをまたいで持続しないので、後始末に要る値(untracked 一覧のパス)は
# **ファイルへ書いて最終行に出す**。呼び出し側はその文字列を teardown.sh へ渡す。
#
# base は「HEAD <base> 形を選んだときだけ」ではなく **常に**解決する。未 push コミットの
# 有無(`rev-list --count <base>..HEAD`)が状態判定そのものに要るため、後回しにすると
# 判定が回らない(循環依存)。
#
# 出力契約(機械解釈は LAUNCH-CMD 行と最終行のみ):
#   LAUNCH-CMD: cd '<repo>' && difit <args>   … READY のときだけ出る
#   LAUNCH-RESULT: READY mode=<mode> untracked=<一覧パス|->
#   LAUNCH-RESULT: AMBIGUOUS(<理由>)  … 未コミット変更と未 push コミットが両方ある
#                                       (1 画面に出せない)。mode を明示して呼び直す
#   LAUNCH-RESULT: EMPTY(<理由>)      … 見せる差分が無い
#   LAUNCH-RESULT: ERROR(<理由>)      … 起動してはいけない(exit 1)
#   exit code: ERROR のみ 1、それ以外は 0。
set -uo pipefail

fail() {
  printf 'LAUNCH-RESULT: ERROR(%s)\n' "$1"
  exit 1
}

# 単一引用符で囲んで安全に貼れる形にする(bash 3.2 に ${var@Q} は無い)。
shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

repo="${1-}"
mode="${2:-auto}"
target="${3-}"
base_arg="${4-}"

[ -n "$repo" ] || fail "repo 未指定"
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "git work tree ではない: $repo"
command -v difit >/dev/null 2>&1 || fail "difit 未導入(mise install で入れる。npx へ落とさない)"

case "$mode" in
auto | worktree | branch | commit) : ;;
*) fail "未知の mode: $mode" ;;
esac

# rev として受け取った文字列に range 記法が混ざると difit が 2 引数形しか取らないので
# 静かに別物を見せる。分解を呼び出し側へ返す。
for r in "$target" "$base_arg"; do
  [ -n "$r" ] || continue
  case "$r" in
  *..*) fail "range 記法は target/base の 2 引数に分解する: $r" ;;
  esac
done

# rev 検証。`git rev-parse --verify -- <rev>` は `--` が pathspec 区切りなので正当な rev でも
# 失敗する。オプション注入は --end-of-options で封じ、commit へ解決できることまで見る。
verify_rev() {
  case "$1" in
  -*) return 1 ;;
  esac
  git -C "$repo" rev-parse --verify --quiet --end-of-options "$1^{commit}" >/dev/null 2>&1
}

# 明示 rev から mode を確定する。
if [ -n "$base_arg" ]; then
  [ -n "$target" ] || fail "base だけ指定されている(target も要る)"
  case "$mode" in
  auto | branch) mode=branch ;;
  *) fail "mode=$mode に rev を 2 個は渡せない" ;;
  esac
elif [ -n "$target" ]; then
  if [ "$target" = "." ]; then
    case "$mode" in
    auto | worktree) mode=worktree ;;
    *) fail "mode=$mode に '.' は渡せない" ;;
    esac
    target=""
  else
    case "$mode" in
    auto | commit) mode=commit ;;
    branch) fail "mode=branch には base も要る" ;;
    *) fail "mode=$mode に rev は渡せない" ;;
    esac
  fi
fi

# ---- 状態判定に要る材料を集める ----

st="$(git -C "$repo" status --porcelain 2>/dev/null)" || fail "status 取得失敗: $repo"
dirty=0
[ -n "$st" ] && dirty=1

# base は lib が単一情報源。構文破損した lib を直 source すると、エラー地点までの定義が
# 現シェルに残る(部分定義)ので、先に subshell で健全性を確かめる。
base=""
base_reason=""
LIB="$HOME/.claude/hooks/lib/resolve-base-ref.sh"
# shellcheck source=/dev/null
if [ ! -r "$LIB" ]; then
  base_reason="lib 不達: resolve-base-ref.sh"
elif ! (. "$LIB") >/dev/null 2>&1; then
  base_reason="lib 破損: resolve-base-ref.sh"
elif ! . "$LIB" 2>/dev/null; then
  base_reason="lib 読込失敗: resolve-base-ref.sh"
elif ! type resolve_base_ref >/dev/null 2>&1; then
  base_reason="lib 旧版: resolve_base_ref 未定義"
else
  # 解決不能は「空 + rc 0」で返る lib 契約なので、実効の防壁は空チェック。
  base="$(resolve_base_ref "$repo" 2>/dev/null)"
  [ -n "$base" ] || base_reason="保護祖先が見つからない"
fi
case "$base" in
-*)
  base=""
  base_reason="base がオプション形"
  ;;
esac

# 未 push コミット数。base か HEAD が解けなければ「不明」(空)にする。0 と混同しない。
ahead=""
if [ -n "$base" ]; then
  if ! verify_rev HEAD; then
    base_reason="HEAD が commit として解決できない(未コミットの新規 repo)"
  elif ! verify_rev "$base"; then
    base_reason="base が commit として解決できない: $base"
    base=""
  else
    ahead="$(git -C "$repo" rev-list --count --end-of-options "$base..HEAD" 2>/dev/null)"
    case "$ahead" in
    '' | *[!0-9]*)
      ahead=""
      base_reason="コミット数を数えられない"
      ;;
    esac
  fi
fi

branchable=0
[ -n "$ahead" ] && [ "$ahead" -gt 0 ] && branchable=1

printf 'LAUNCH: repo=%s dirty=%s ahead=%s base=%s\n' \
  "$repo" "$dirty" "${ahead:-unknown}" "${base:-none${base_reason:+ (}${base_reason}${base_reason:+)}}"

# ---- mode=auto の決定 ----

if [ "$mode" = auto ]; then
  if [ "$dirty" -eq 1 ] && [ "$branchable" -eq 1 ]; then
    printf 'LAUNCH-RESULT: AMBIGUOUS(未コミット変更と未 push コミットが両方ある。mode に worktree か branch を指定して呼び直す)\n'
    exit 0
  elif [ "$dirty" -eq 1 ]; then
    mode=worktree
  elif [ "$branchable" -eq 1 ]; then
    mode=branch
  elif [ -z "$ahead" ]; then
    # 未 push コミットの有無が分からないまま「差分なし」と言うと誤結論になる。
    fail "状態を判定できない(${base_reason:-base 解決不能})。target/base を明示して呼び直す"
  else
    printf 'LAUNCH-RESULT: EMPTY(未コミット変更も未 push コミットも無い)\n'
    exit 0
  fi
fi

# ---- 起動コマンドの組み立て ----

ulist="-"
args=""
case "$mode" in
worktree)
  [ -z "$base_arg" ] || fail "mode=worktree に base は渡せない"
  # untracked 一覧は difit が `git add --intent-to-add` を撃つ**前**にここで採る。
  # 撃った後は ls-files --others に出なくなるので、後から取り直すと空になる。
  ulist="$(mktemp "${TMPDIR:-/tmp}/difit-untracked.XXXXXX")" || fail "一時ファイルを作れない"
  # -z なので core.quotePath の影響を受けず、改行入りパスも壊れない。
  git -C "$repo" ls-files -z --others --exclude-standard >"$ulist" 2>/dev/null \
    || fail "untracked 一覧を取得できない"
  un="$(tr -dc '\0' <"$ulist" | wc -c | tr -d ' ')"
  printf 'LAUNCH: untracked=%s 件を無認証ポートへ配信する\n' "$un"
  args=". --include-untracked --clean"
  ;;
branch)
  t="${target:-HEAD}"
  b="${base_arg:-$base}"
  [ -n "$b" ] || fail "base を解決できない(${base_reason:-理由不明})"
  verify_rev "$t" || fail "target が rev として解決できない: $t"
  verify_rev "$b" || fail "base が rev として解決できない: $b"
  # --merge-base が無いと二点差分になり、分岐後に base へ入った他人のコミットが
  # 反転表示で混ざる。base は第 2 引数(多くのツールと逆)。
  args="$(shq "$t") $(shq "$b") --merge-base --clean"
  ;;
commit)
  verify_rev "$target" || fail "rev として解決できない: $target"
  args="$(shq "$target") --clean"
  ;;
esac

printf 'LAUNCH-CMD: cd %s && difit %s\n' "$(shq "$repo")" "$args"
printf 'LAUNCH-RESULT: READY mode=%s untracked=%s\n' "$mode" "$ulist"
exit 0
