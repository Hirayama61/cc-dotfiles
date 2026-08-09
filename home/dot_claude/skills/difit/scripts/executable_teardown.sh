#!/usr/bin/env bash
# teardown.sh — difit skill 手順 5: index 復元とサーバ停止。
#
# Usage: teardown.sh <repo|-> <untracked-list|-> <port|->
#   repo            … 対象 repo の絶対パス。index 復元が要らないなら `-`。
#   untracked-list  … build-launch.sh が出した NUL 区切り一覧のパス。無ければ `-`。
#   port            … 起動ログの `🚀 difit server started on http://localhost:<port>` の数値。
#                     停止が要らないなら `-`。
#
# 2 つの後始末は独立に実行する(片方が失敗しても、もう片方は撃つ)。値はすべて引数で
# 受け取る — シェル変数は Bash 呼び出しをまたいで持続しないため。
#
# 出力契約(機械解釈は最終行のみ):
#   TEARDOWN-RESULT: DONE
#   TEARDOWN-RESULT: ERROR(<理由>)   … exit 1
set -uo pipefail

repo="${1--}"
ulist="${2--}"
port="${3--}"
err=0

# 記録した一覧のうち **intent-to-add のまま(porcelain の XY が ` A`)のものだけ**を
# NUL 区切りで stdout に出す。
#
# 一覧は difit 起動時点の untracked なので、その後に人間が本当に `git add` したファイルが
# 混ざる。実 add(`A `)まで reset すると staged 内容が index から落ちるため、ここで絞る。
#
# pathspec は GIT_LITERAL_PATHSPECS=1 で literal 固定にする。`--` はオプション解釈を
# 止めるだけで先頭 `:` の pathspec magic は生きており、`:` という名の untracked が 1 つ
# あるだけで repo 全体が対象になる(`:!keep.txt` なら「keep.txt 以外を全部」)。
# git 側に渡すのは status も reset も同じ経路なので、両方に効かせる。
select_intent_to_add() {
  local raw entry xy path orig
  raw="$1"
  GIT_LITERAL_PATHSPECS=1 xargs -0 git -C "$repo" status --porcelain -z -- <"$ulist" >"$raw" 2>/dev/null || return 1
  while IFS= read -r -d '' entry; do
    xy="${entry:0:2}"
    path="${entry:3}"
    # -z の rename/copy は「新パス\0旧パス\0」の 2 フィールド。旧パスを読み捨てないと
    # 次のエントリの XY 解釈が 1 つずれる。
    case "$xy" in
    R? | C?) IFS= read -r -d '' orig || orig="" ;;
    esac
    if [ "$xy" = " A" ]; then
      printf '%s\0' "$path"
    fi
  done <"$raw"
  return 0
}

# ---- index 復元 ----
# difit の --include-untracked は `git add --intent-to-add` を撃つので、放置すると
# `git status` に staged として残り次の commit に混ざる。
if [ -z "$ulist" ] || [ "$ulist" = "-" ]; then
  printf 'TEARDOWN: index skip(一覧未指定)\n'
elif [ -z "$repo" ] || [ "$repo" = "-" ]; then
  printf 'TEARDOWN: index skip(repo 未指定で復元できない)\n'
  err=1
elif ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'TEARDOWN: index skip(git work tree ではない: %s)\n' "$repo"
  err=1
elif [ ! -f "$ulist" ]; then
  printf 'TEARDOWN: index skip(一覧不達: %s)\n' "$ulist"
  err=1
elif [ ! -s "$ulist" ]; then
  # 一覧が空のまま reset を撃つと pathspec 無しの mixed reset になり、difit と無関係な
  # staged 変更まで全部 unstage する。BSD xargs は空入力でコマンドを起動しないが、
  # GNU xargs は -r が無いと 1 回起動するので、環境に依らせずここで止める。
  printf 'TEARDOWN: index skip(untracked なし)\n'
  rm -f "$ulist"
else
  n="$(tr -dc '\0' <"$ulist" | wc -c | tr -d ' ')"
  raw="$(mktemp "${TMPDIR:-/tmp}/difit-status.XXXXXX" 2>/dev/null)" || raw=""
  ia="$(mktemp "${TMPDIR:-/tmp}/difit-ia.XXXXXX" 2>/dev/null)" || ia=""
  if [ -z "$raw" ] || [ -z "$ia" ]; then
    printf 'TEARDOWN: index skip(一時ファイルを作れない recorded=%s)\n' "$n"
    err=1
  elif ! select_intent_to_add "$raw" >"$ia"; then
    printf 'TEARDOWN: index 復元 失敗(status を取得できない recorded=%s)\n' "$n"
    err=1
  elif [ ! -s "$ia" ]; then
    # 記録した全部が既に別の状態(人間が add した / 消した)。撃つ対象が無い。
    # 空のまま reset を撃つと pathspec 無しの mixed reset になるのでここで止める。
    printf 'TEARDOWN: index skip(intent-to-add なし recorded=%s)\n' "$n"
    rm -f "$ulist"
  else
    m="$(tr -dc '\0' <"$ia" | wc -c | tr -d ' ')"
    if GIT_LITERAL_PATHSPECS=1 xargs -0 git -C "$repo" reset -q -- <"$ia"; then
      printf 'TEARDOWN: index 復元 files=%s recorded=%s\n' "$m" "$n"
      rm -f "$ulist"
    else
      printf 'TEARDOWN: index 復元 失敗(files=%s recorded=%s)\n' "$m" "$n"
      err=1
    fi
  fi
  [ -n "$raw" ] && rm -f "$raw"
  [ -n "$ia" ] && rm -f "$ia"
fi

# ---- サーバ停止 ----
# 人間がブラウザを開かなかった場合は接続が一度も無く、切断も起きないので終了しない。
# 停止は SIGTERM(既定)。コメントは手順 4 で回収済みなので、SIGTERM で終了時 stdout の
# コメント出力が出ないことは問題にならない。
stop_server() {
  case "$port" in
  '' | '-') printf 'TEARDOWN: server skip(port 未指定)\n'; return 0 ;;
  *[!0-9]*) printf 'TEARDOWN: server skip(port が不正: %s)\n' "$port"; return 0 ;;
  esac
  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    printf 'TEARDOWN: server skip(port が範囲外: %s)\n' "$port"
    return 0
  fi
  command -v lsof >/dev/null 2>&1 || {
    printf 'TEARDOWN: server skip(lsof 不在)\n'
    return 0
  }

  local pids p cmd
  pids="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null)"
  if [ -z "$pids" ]; then
    printf 'TEARDOWN: server skip(listener なし port=%s)\n' "$port"
    return 0
  fi
  for p in $pids; do
    case "$p" in
    '' | *[!0-9]*) continue ;;
    esac
    # difit が既に終了していて OS が同じ port を別プロセスへ割り当てていると、
    # 確認せずに撃つと無関係なプロセスを落とす。`pgrep -f difit` は使わない
    # (コマンドライン全体照合なので、この skill を開いたエディタにも当たる)。
    cmd="$(ps -o command= -p "$p" 2>/dev/null)"
    case "$cmd" in
    *difit*)
      if kill "$p" 2>/dev/null; then
        printf 'TEARDOWN: server stop pid=%s\n' "$p"
      else
        printf 'TEARDOWN: server 停止失敗 pid=%s\n' "$p"
        err=1
      fi
      ;;
    *) printf 'TEARDOWN: server skip(pid=%s は difit ではない)\n' "$p" ;;
    esac
  done
  return 0
}
stop_server

if [ "$err" -eq 0 ]; then
  printf 'TEARDOWN-RESULT: DONE\n'
  exit 0
fi
printf 'TEARDOWN-RESULT: ERROR(後始末の一部が失敗した。上の行を確認する)\n'
exit 1
