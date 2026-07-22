#!/usr/bin/env bash
# dev-pipeline レートリミット自動再開タイマー(経路 A)。
#
# 被運転セッションが usage limit で止まったとき、素のシェル(Claude のレートリミットを
# 消費しない)が対象 pane を周期監視し、明けたら再開フレーズを 1 度送る。指揮者が
# Monitor でこの出力を回収し、経路 B 切替などの遷移判断を行う(このスクリプト自身は
# 経路 B へ遷移しない)。設計の状態機械は Plan v2 §2.3 / §7.4。
#
# Usage: rate-limit-resume.sh <target> [<phrase>]
#        rate-limit-resume.sh --parse-reset   (stdin の banner から明けまで秒を stdout。自己テスト用)
#        rate-limit-resume.sh --print-permission-ere   (権限プロンプト検知 ERE を stdout。運転元の単一情報源)
#   <target>  tmux の pane 指定(session:window.pane または %pane_id)。起動時に一度
#             %pane_id へ解決し、以後の送信・監視はすべて解決済み pane_id に固定する。
#   <phrase>  再開時に送る 1 行(既定「再開して」)。
#
# 終了コード:
#   0  再開成功(送信後に banner が消え claude が生存 = ack 成立)
#   2  経路 B が必要(pane が別プロセスに置換 / claude 消失 / pane 解決不能)
#   3  タイムアウト(RLR_MAX_ITER 到達)
#   4  再送上限到達(RLR_MAX_RESEND 回送っても banner が残る)
#   5  権限プロンプト滞留(誰も答えないまま RLR_PERMSTUCK_MAX_ITERS 回。指揮者へ委譲)
#   1  使用方法エラー
#
# 環境変数(既定は実運用値):
#   RLR_POLL_INTERVAL       ポーリング間隔秒(既定 60)。テストは 0。
#   RLR_MAX_ITER            最大反復(既定 0 = 無制限)。テストは有限。
#   RLR_MAX_RESEND          ack 失敗時の再送上限(既定 3)。
#   RLR_PERMSTUCK_MAX_ITERS 権限プロンプト連続滞留で exit 5 する反復上限(既定 120 ≒ 2h)。0 = 無制限。
#   RLR_SEND_DELAY          literal 送信と Enter の間の待ち秒(既定 1)。テストは 0。
#   RLR_TMUX                tmux コマンド(既定 tmux)。テストは PATH shim か明示注入。
#   RLR_RESET_PARSE         指定時、banner 全文を stdin で渡して「明けまでの sleep 秒」を
#                           stdout に返す外部コマンド(内蔵パーサより優先)。
#   RLR_SIGNAL_FILE         指定時、状態行を追記する合図ファイル(指揮者が回収)。
set -euo pipefail

PROG="${0##*/}"

is_shell_cmd() {
  case "$1" in
  zsh | -zsh | bash | -bash | sh | -sh | fish | -fish) return 0 ;;
  *) return 1 ;;
  esac
}

has_limit() {
  printf '%s' "$1" | grep -qiE 'usage limit|rate limit|使用制限|利用上限'
}

# 権限プロンプト検知は fail-closed に倒す(単一情報源)。送信判定が否定形
# (limit でも permission でもない=通常 → 送る)である以上、検知漏れは誤送信=承認の
# 肩代わり(permission laundering)に直結する。よって「プロンプトらしさ」を広めに拾い、
# 疑わしきは送らない。過検知で送れない場合は permission-stuck(exit 5)が後ろ盾になり
# デッドロックを避ける。`grep -i` で大小無視、`[[:space:]]` で BSD/GNU 両対応。
# カーソルは ❯ に限らず ASCII `>` や別グリフもありうるので広めの文字クラスにする。
# 判定は pane 末尾のみを対象にして(呼び出し側で tail 済み)、過去会話の同種文言による
# 誤検知を抑える。
# カーソル+選択肢は番号の直後に . か ) を必須にする(`> 123 files` 等の通常出力の誤検知回避)。
PERMISSION_ERE='do you want to|do you trust|allow this (command|tool|edit|action)|approve (running|this)|overwrite (the |existing |this )|[❯▶►>][[:space:]]*([0-9]+[.)]|yes\b|no\b)|\[y/n\]|\(y/n\)|press .*to (confirm|approve)|(実行|続行|作成|変更|適用|削除|上書き|許可)して?も?(よろしいですか|いいですか|よろしいでしょうか)|しますか[?？]'
has_permission() {
  printf '%s' "$1" | grep -qiE "$PERMISSION_ERE"
}

default_reset_seconds() {
  # banner から「明けまでの秒数」を best-effort で読む。少しでも怪しければ 0 を返し、
  # 呼び出し側は POLL_INTERVAL にフォールバックする(バナー書式に hard 依存しない)。
  # 抽出値は必ず 10# で 10 進固定(先頭ゼロ 08/09 の 8 進クラッシュを防ぐ)。
  local t secs=0 n h m ampm clk now_hms now_sod tgt_sod
  t="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  # 相対時刻は limit/reset 文脈に固定する(通常出力の "completed in 2 hours" 等の誤採用を防ぐ)。
  if printf '%s' "$t" | grep -qE '(again|retry|reset|try|limit|available)[^0-9]{0,20}in [0-9]+ ?(hour|hr)'; then
    n="$(printf '%s' "$t" | grep -oE 'in [0-9]+ ?(hour|hr)' | grep -oE '[0-9]+' | head -1)"
    secs=$((10#$n * 3600))
  elif printf '%s' "$t" | grep -qE '(again|retry|reset|try|limit|available)[^0-9]{0,20}in [0-9]+ ?(minute|min)'; then
    n="$(printf '%s' "$t" | grep -oE 'in [0-9]+ ?(minute|min)' | grep -oE '[0-9]+' | head -1)"
    secs=$((10#$n * 60))
  elif printf '%s' "$t" | grep -qE '(reset|again|available|retry)[^0-9]*at [0-9]{1,2}(:[0-9]{2})? ?(am|pm)?'; then
    clk="$(printf '%s' "$t" | grep -oE 'at [0-9]{1,2}(:[0-9]{2})? ?(am|pm)?' | head -1)"
    h="$(printf '%s' "$clk" | grep -oE '[0-9]{1,2}' | head -1 || true)"
    # 分は省略可(例 "at 5pm")。pipefail 下で grep 不一致がスクリプトを落とさないよう || true。
    m="$(printf '%s' "$clk" | grep -oE ':[0-9]{2}' | head -1 | tr -d ':' || true)"
    [ -z "$m" ] && m=0
    [ -z "$h" ] && h=0
    ampm="$(printf '%s' "$clk" | grep -oE 'am|pm' || true)"
    h=$((10#$h))
    m=$((10#$m))
    case "$ampm" in
    pm) [ "$h" -lt 12 ] && h=$((h + 12)) ;;
    am) [ "$h" -eq 12 ] && h=0 ;;
    esac
    # 不正な時刻(25:99 等)は誤パースとして捨てる(0 → interval フォールバック)。
    if [ "$h" -gt 23 ] || [ "$m" -gt 59 ]; then
      printf '0'
      return 0
    fi
    now_hms="$(date +%H:%M:%S)"
    now_sod=$((10#${now_hms%%:*} * 3600 + 10#$(printf '%s' "$now_hms" | cut -d: -f2) * 60 + 10#$(printf '%s' "$now_hms" | cut -d: -f3)))
    tgt_sod=$((h * 3600 + m * 60))
    secs=$((tgt_sod - now_sod))
    [ "$secs" -le 0 ] && secs=$((secs + 86400))
  fi
  # 妥当域(1 分〜6 時間)外は誤パースとみなし 0(= interval フォールバック)。
  if [ "$secs" -ge 60 ] && [ "$secs" -le 21600 ]; then
    printf '%s' "$secs"
  else
    printf '0'
  fi
}

# 自己テストフック: 内蔵リセット時刻パーサを stdin で単体検証する(ループを回さない)。
if [ "${1:-}" = "--parse-reset" ]; then
  default_reset_seconds "$(cat)"
  exit 0
fi

# 公開口: 権限プロンプト検知 ERE を 1 行で出力する(ループを回さない)。
# home-claude-drive 等の運転元がナッジ送信前の機械照合に使う単一情報源。
# ERE を転記・grep 抽出で複製せず、必ずこの口から取得する。
if [ "${1:-}" = "--print-permission-ere" ]; then
  printf '%s\n' "$PERMISSION_ERE"
  exit 0
fi

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $PROG <target> [<phrase>]" >&2
  exit 1
fi

TARGET="$1"
PHRASE="${2:-再開して}"

POLL_INTERVAL="${RLR_POLL_INTERVAL:-60}"
MAX_ITER="${RLR_MAX_ITER:-0}"
MAX_RESEND="${RLR_MAX_RESEND:-3}"
PERMSTUCK_MAX_ITERS="${RLR_PERMSTUCK_MAX_ITERS:-120}"
SEND_DELAY="${RLR_SEND_DELAY:-1}"
TMUX="${RLR_TMUX:-tmux}"

emit() {
  printf 'RLR: %s\n' "$1"
  if [ -n "${RLR_SIGNAL_FILE:-}" ]; then
    printf 'RLR: %s\n' "$1" >>"$RLR_SIGNAL_FILE"
  fi
}

_last_state=""
emit_state() {
  # 待機系の反復イベントは状態変化時だけ出す(signal file 肥大・重複ナッジ回避)。
  [ "$1" = "$_last_state" ] && return 0
  _last_state="$1"
  emit "$1"
}

tmux_q() {
  "$TMUX" display-message -p -t "$PANE_ID" "$1" 2>/dev/null || true
}

send_phrase() {
  # send-keys を set -e で無言死させない。TOCTOU の送信失敗は経路 B(exit 2)扱い。
  if ! "$TMUX" send-keys -t "$PANE_ID" -l "$PHRASE"; then
    emit "route-b send-failed literal"
    exit 2
  fi
  # 多バイトフレーズが TUI で確定する前に Enter が先着すると取りこぼす → 待ちを挟む。
  [ "$SEND_DELAY" -gt 0 ] 2>/dev/null && sleep "$SEND_DELAY" || true
  if ! "$TMUX" send-keys -t "$PANE_ID" Enter; then
    emit "route-b send-failed enter"
    exit 2
  fi
}

sleep_poll() {
  [ "$POLL_INTERVAL" -gt 0 ] 2>/dev/null && sleep "$POLL_INTERVAL" || true
}

# リセット期限は初回だけ確定して保持する(相対時刻 "in 2 hours" を毎ポーリング再解釈して
# 永久に待つバグ・通常出力の同種文言の誤作動を防ぐ)。banner が消えたら reset_deadline で 0 へ。
deadline_epoch=0
sleep_reset() {
  local now secs remaining
  now="$(date +%s)"
  if [ "$deadline_epoch" -eq 0 ]; then
    if [ -n "${RLR_RESET_PARSE:-}" ]; then
      secs="$(printf '%s' "$1" | "$RLR_RESET_PARSE" 2>/dev/null || true)"
    else
      secs="$(default_reset_seconds "$1")"
    fi
    case "$secs" in '' | *[!0-9]*) secs=0 ;; esac
    [ "$secs" -gt 0 ] && deadline_epoch=$((now + secs))
  fi
  if [ "$deadline_epoch" -gt "$now" ]; then
    remaining=$((deadline_epoch - now))
    # 一括長時間 sleep は pane 消失・置換・権限プロンプトを見逃す。最大 5 分刻みで
    # deadline へ近づき、毎チャンクでループが状態を再確認できるようにする。
    [ "$remaining" -gt 300 ] && remaining=300
    sleep "$remaining"
  else
    sleep_poll
  fi
}
reset_deadline() { deadline_epoch=0; }

# ── 起動時: target を %pane_id へ解決し、pane プロセスの identity を固定 ──
PANE_ID="$TARGET"
resolved="$("$TMUX" display-message -p -t "$TARGET" '#{pane_id}' 2>/dev/null || true)"
[ -n "$resolved" ] && PANE_ID="$resolved"
START_PANE_PID="$(tmux_q '#{pane_pid}')"

if [ -z "$START_PANE_PID" ]; then
  emit "route-b pane-unresolved target=$TARGET"
  exit 2
fi

sent=0
resend=0
seen_limit=0
perm_iters=0
iter=0

while :; do
  iter=$((iter + 1))
  if [ "$MAX_ITER" -gt 0 ] && [ "$iter" -gt "$MAX_ITER" ]; then
    emit "timeout iter=$iter"
    exit 3
  fi

  cur_cmd="$(tmux_q '#{pane_current_command}')"
  cur_pid="$(tmux_q '#{pane_pid}')"

  if [ -z "$cur_pid" ]; then
    emit "route-b pane-lost"
    exit 2
  fi
  if [ "$cur_pid" != "$START_PANE_PID" ]; then
    emit "route-b pane-replaced pid=$cur_pid"
    exit 2
  fi
  if [ -n "$cur_cmd" ] && is_shell_cmd "$cur_cmd"; then
    emit "route-b claude-exited cmd=$cur_cmd"
    exit 2
  fi

  if ! screen="$("$TMUX" capture-pane -p -t "$PANE_ID" 2>/dev/null)"; then
    emit_state "capture-retry"
    sleep_poll
    continue
  fi
  # 判定は pane 末尾のみ(banner・プロンプトは最下部に描画される)。過去会話の同種文言に
  # よる権限誤検知・リセット時刻の誤マッチを避ける。
  text="$(printf '%s\n' "$screen" | tail -n 25)"

  # 権限プロンプトには絶対に送らない。滞留し続けたら exit 5 で指揮者へ委譲(無限ループ回避)。
  if has_permission "$text"; then
    perm_iters=$((perm_iters + 1))
    if [ "$PERMSTUCK_MAX_ITERS" -gt 0 ] && [ "$perm_iters" -ge "$PERMSTUCK_MAX_ITERS" ]; then
      emit "permission-stuck iters=$perm_iters"
      exit 5
    fi
    emit_state "permission-prompt human-needed"
    reset_deadline
    sleep_poll
    continue
  fi
  perm_iters=0

  if has_limit "$text"; then
    seen_limit=1
    if [ "$sent" -eq 1 ]; then
      if [ "$resend" -lt "$MAX_RESEND" ]; then
        send_phrase
        resend=$((resend + 1))
        emit "resend n=$resend"
        sleep_poll
        continue
      fi
      emit "resend-exhausted n=$resend"
      exit 4
    fi
    emit_state "limited waiting"
    sleep_reset "$text" # 明けまでの期限を一度確定して待つ
    continue
  fi

  # banner 無し・claude 生存・権限プロンプト無し = 通常状態。期限をリセット。
  reset_deadline
  if [ "$seen_limit" -eq 1 ] && [ "$sent" -eq 0 ]; then
    send_phrase
    sent=1
    emit "sent"
    sleep_poll
    continue
  fi
  if [ "$sent" -eq 1 ]; then
    emit "resumed"
    exit 0
  fi

  # まだ limit を観測していない(banner 描画前など)→ 周期確認を続ける。
  sleep_poll
done
