#!/usr/bin/env bash
# dev-pipeline レートリミット自動再開タイマー(経路 A)。
#
# 被運転セッションが usage limit で止まったとき、素のシェル(Claude のレートリミットを
# 消費しない)が対象 pane を周期監視し、明けたら再開フレーズを 1 度送る。指揮者が
# Monitor でこの出力を回収し、経路 B 切替などの遷移判断を行う(このスクリプト自身は
# 経路 B へ遷移しない)。設計の状態機械は Plan v2 §2.3 / §7.4。
#
# Usage: rate-limit-resume.sh <target> [<phrase>]
#   <target>  tmux の pane 指定(session:window.pane または %pane_id)。起動時に一度
#             %pane_id へ解決し、以後の送信・監視はすべて解決済み pane_id に固定する
#             (pane index 変更・window 再配置後も別 pane へ誤送信しない)。
#   <phrase>  再開時に送る 1 行(既定「再開して」)。
#
# 終了コード:
#   0  再開成功(送信後に banner が消え claude が生存 = ack 成立)
#   2  経路 B が必要(pane が別プロセスに置換 / claude 消失)
#   3  タイムアウト(RLR_MAX_ITER 到達)
#   4  再送上限到達(RLR_MAX_RESEND 回送っても banner が残る)
#   1  使用方法エラー
#
# テスト/運用パラメータ(環境変数。既定は実運用値):
#   RLR_POLL_INTERVAL  ポーリング間隔秒(既定 60)。テストは 0。
#   RLR_MAX_ITER       最大反復(既定 0 = 無制限)。テストは有限。
#   RLR_MAX_RESEND     ack 失敗時の再送上限(既定 3)。
#   RLR_TMUX           tmux コマンド(既定 tmux)。テストは PATH shim か明示注入。
#   RLR_RESET_PARSE    指定時、banner 全文を stdin で渡して「明けまでの sleep 秒」を
#                      stdout に返す外部コマンド。未指定/失敗時は RLR_POLL_INTERVAL で
#                      周期確認を続ける(リセット時刻バナーの書式に hard 依存しない)。
#   RLR_SIGNAL_FILE    指定時、状態行を追記する合図ファイル(指揮者が回収)。
set -euo pipefail

PROG="${0##*/}"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $PROG <target> [<phrase>]" >&2
  exit 1
fi

TARGET="$1"
PHRASE="${2:-再開して}"

POLL_INTERVAL="${RLR_POLL_INTERVAL:-60}"
MAX_ITER="${RLR_MAX_ITER:-0}"
MAX_RESEND="${RLR_MAX_RESEND:-3}"
TMUX="${RLR_TMUX:-tmux}"

emit() {
  # 状態を stdout と(あれば)合図ファイルへ。指揮者が Monitor で回収する。
  printf 'RLR: %s\n' "$1"
  if [ -n "${RLR_SIGNAL_FILE:-}" ]; then
    printf 'RLR: %s\n' "$1" >>"$RLR_SIGNAL_FILE"
  fi
}

tmux_q() {
  # display-message でフォーマット値を 1 行取得。
  "$TMUX" display-message -p -t "$PANE_ID" "$1" 2>/dev/null || true
}

is_shell_cmd() {
  # pane の前景コマンドがシェルなら claude は終了している(経路 B)。
  case "$1" in
  zsh | -zsh | bash | -bash | sh | -sh | fish | -fish) return 0 ;;
  *) return 1 ;;
  esac
}

has_limit() {
  printf '%s' "$1" | grep -qiE 'usage limit|rate limit|使用制限|利用上限'
}

has_permission() {
  printf '%s' "$1" | grep -qE 'Do you want to proceed|❯ 1\. Yes|^\s*1\. Yes'
}

sleep_interval() {
  # RLR_RESET_PARSE があれば banner から明けまで秒を得て sleep、無ければ interval。
  local secs="$POLL_INTERVAL"
  if [ -n "${RLR_RESET_PARSE:-}" ]; then
    local parsed
    parsed="$(printf '%s' "$1" | "$RLR_RESET_PARSE" 2>/dev/null || true)"
    case "$parsed" in
    '' | *[!0-9]*) : ;; # 非数値/空はパース失敗 → interval を使う
    *) secs="$parsed" ;;
    esac
  fi
  [ "$secs" -gt 0 ] 2>/dev/null && sleep "$secs" || true
}

# ── 起動時: target を %pane_id へ解決し、pane プロセスの identity を固定 ──
PANE_ID="$TARGET"
resolved="$("$TMUX" display-message -p -t "$TARGET" '#{pane_id}' 2>/dev/null || true)"
[ -n "$resolved" ] && PANE_ID="$resolved"
START_PANE_PID="$(tmux_q '#{pane_pid}')"

sent=0
resend=0
seen_limit=0
iter=0

while :; do
  iter=$((iter + 1))
  if [ "$MAX_ITER" -gt 0 ] && [ "$iter" -gt "$MAX_ITER" ]; then
    emit "timeout iter=$iter"
    exit 3
  fi

  cur_cmd="$(tmux_q '#{pane_current_command}')"
  cur_pid="$(tmux_q '#{pane_pid}')"

  # identity 変化 = pane が別プロセスに置換 → 経路 B。
  if [ -n "$START_PANE_PID" ] && [ -n "$cur_pid" ] && [ "$cur_pid" != "$START_PANE_PID" ]; then
    emit "route-b pane-replaced pid=$cur_pid"
    exit 2
  fi
  # claude 消失(前景がシェル)→ 経路 B。
  if [ -n "$cur_cmd" ] && is_shell_cmd "$cur_cmd"; then
    emit "route-b claude-exited cmd=$cur_cmd"
    exit 2
  fi

  text="$("$TMUX" capture-pane -p -t "$PANE_ID" 2>/dev/null || true)"

  # 権限プロンプトには絶対に送らない(誤送信・permission laundering 回避)。人間へ。
  if has_permission "$text"; then
    emit "permission-prompt human-needed"
    sleep_interval "$text"
    continue
  fi

  if has_limit "$text"; then
    seen_limit=1
    if [ "$sent" -eq 1 ]; then
      # 送信後に banner が戻った = ack 失敗 → 上限まで再送。
      if [ "$resend" -lt "$MAX_RESEND" ]; then
        "$TMUX" send-keys -t "$PANE_ID" -l "$PHRASE"
        "$TMUX" send-keys -t "$PANE_ID" Enter
        resend=$((resend + 1))
        emit "resend n=$resend"
        sleep_interval "$text"
        continue
      fi
      emit "resend-exhausted n=$resend"
      exit 4
    fi
    emit "limited waiting"
    sleep_interval "$text"
    continue
  fi

  # banner 無し・claude 生存・権限プロンプト無し = 通常状態。
  if [ "$seen_limit" -eq 1 ] && [ "$sent" -eq 0 ]; then
    # 明けた。1 明け = 1 送信。
    "$TMUX" send-keys -t "$PANE_ID" -l "$PHRASE"
    "$TMUX" send-keys -t "$PANE_ID" Enter
    sent=1
    emit "sent"
    sleep_interval "$text"
    continue
  fi
  if [ "$sent" -eq 1 ]; then
    # 送信済みで banner が消え生存 = ack 成立。
    emit "resumed"
    exit 0
  fi

  # まだ limit を観測していない(banner 描画前など)→ 周期確認を続ける。
  sleep_interval "$text"
done
