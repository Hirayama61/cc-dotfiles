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
  if xargs -0 git -C "$repo" reset -q -- <"$ulist"; then
    printf 'TEARDOWN: index 復元 files=%s\n' "$n"
    rm -f "$ulist"
  else
    printf 'TEARDOWN: index 復元 失敗(files=%s)\n' "$n"
    err=1
  fi
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
