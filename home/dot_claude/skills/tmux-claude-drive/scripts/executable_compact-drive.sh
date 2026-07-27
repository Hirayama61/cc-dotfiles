#!/usr/bin/env bash
# compact 代行(経路: 作業者 pane へ /compact-prep → /compact を送る)。tmux-claude-drive の
# 付属部品で、運転元(pane-claude-drive 等)が pane ごとに背景 1 本で起動する。
#
# 送信判定が否定形(「送ってはいけない状態でなければ送る」)なので、判定不能はすべて
# 送らない側へ倒す。権限プロンプト・レートリミット banner・スピナーの ERE と
# 「シェル前面化」判定は rate-limit-resume.sh の公開口、cache パスと鮮度しきい値は
# hooks/lib/context-paths.sh が単一情報源で、ここには複製しない。
# 検知語そのものを説明文へ書き写さない(pane に出た自分のソースを監視側が拾って誤検知する)。
#
# Usage: compact-drive.sh <pane_id> <worktree>   判定 → 送信(prep → compact)
#        compact-drive.sh --status <worktree>    ctx と pct の報告のみ(送信しない)
#
# 終了コード(rate-limit-resume.sh とは別体系。出力 prefix ACD:/RLR: で見分ける):
#   0  compact 成立(compacted marker で確認)/ --status で送信可能な状態
#   2  何もしない(pct が代行ライン未満・usage.json 不在/stale・ctx 一致 0 件)
#   3  今は送れない(非 idle・権限プロンプト・limit banner・他の代行が進行中・
#      pane 属性が読めない cmd-unreadable・公開口が答えない shell-probe-failed 等)
#   4  人間が要る(ctx 曖昧・自 pane 不明・state 不正・compact 未成立・pane 消失・jq 不在・
#      環境変数不正 bad-env・ロック所有の喪失 lock-lost・シグナル中断・aborted・
#      未送信の literal が入力欄に残った literal-pending)
#   1  使用方法エラー
#
# 環境変数(既定は実運用値。テストは短縮する):
#   ACD_THRESHOLD        代行ライン(既定 40。提案ライン 30 と最終通告ライン 50 の間)
#   ACD_STALE_SECS       usage.json の鮮度しきい値(既定 lib の stale-secs)
#   ACD_TMUX             tmux コマンド(既定 tmux)
#   ACD_IDLE_CHECKS      idle と見なすスピナー不在の連続回数(既定 2)
#   ACD_IDLE_INTERVAL    idle 判定の間隔秒(既定 5)
#   ACD_SEND_ACK_TIMEOUT 送信成立(スピナー出現 or state 更新)の待ち秒(既定 15)
#   ACD_PREP_TIMEOUT     /compact-prep 完了待ちの上限秒(既定 600)
#   ACD_COMPACT_TIMEOUT  compacted marker 待ちの上限秒(既定 180)
#   ACD_SEND_DELAY       literal 送信と Enter の間の待ち秒(既定 1)
#   ACD_SELF_PANE        自 pane id($TMUX_PANE が無い環境向け)
#   ACD_SIGNAL_FILE      状態行を追記する合図ファイル(運転元が回収)
#   ACD_SCAN_LINES       transcript から cwd を探す末尾行数(既定 50)
set -euo pipefail

PROG="${0##*/}"

TMUX="${ACD_TMUX:-tmux}"
THRESHOLD="${ACD_THRESHOLD:-40}"
IDLE_CHECKS="${ACD_IDLE_CHECKS:-2}"
IDLE_INTERVAL="${ACD_IDLE_INTERVAL:-5}"
SEND_ACK_TIMEOUT="${ACD_SEND_ACK_TIMEOUT:-15}"
PREP_TIMEOUT="${ACD_PREP_TIMEOUT:-600}"
COMPACT_TIMEOUT="${ACD_COMPACT_TIMEOUT:-180}"
SEND_DELAY="${ACD_SEND_DELAY:-1}"
SCAN_LINES="${ACD_SCAN_LINES:-50}"

CTX_LIB="$HOME/.claude/hooks/lib/context-paths.sh"
RLR="$HOME/.claude/skills/tmux-claude-drive/scripts/rate-limit-resume.sh"
VALIDATE_STATE="$HOME/.claude/skills/compact-prep/scripts/validate-state.sh"

PANE=""
PANE_LABEL="-"
LOCK=""
LOCK_OWNED=0
BASELINE=""

emit() {
  printf 'ACD: pane=%s %s\n' "$PANE_LABEL" "$1"
  if [ -n "${ACD_SIGNAL_FILE:-}" ]; then
    printf 'ACD: pane=%s %s\n' "$PANE_LABEL" "$1" >>"$ACD_SIGNAL_FILE"
  fi
}

# ロックは自分が持っている時だけ外す。所有が他へ移った後に消すと、その持ち主が
# 送信の途中で解錠され、同じ pane へ 2 本目が入る(このロック唯一の目的が壊れる)。
cleanup() {
  if [ -n "$BASELINE" ]; then
    rm -f "$BASELINE" 2>/dev/null || true
  fi
  if [ "$LOCK_OWNED" -eq 1 ] && [ -n "$LOCK" ] && own_lock; then
    rm -rf "$LOCK" 2>/dev/null || true
  fi
  LOCK_OWNED=0
  return 0
}

# 終端は必ずここを通す。背景実行では回収路が signal file なので、終了コード相当を
# 1 行残さないと運転元が exit 2 と 3 を区別できない。
FINISHED=0
finish() {
  FINISHED=1
  emit "done rc=$1 reason=$2"
  cleanup
  exit "$1"
}

# finish を通らない終わり方(set -e の中断・シグナル)でも終端行を必ず残す。
# 回収路は signal file と exit status の 2 系統あるので、報告した rc に exit status も
# 揃える(揃えないと中断が 1 = 使用方法エラーとして前景の呼び出し元に届く)。
on_exit() {
  if [ "$FINISHED" -eq 0 ]; then
    emit "done rc=4 reason=aborted"
    cleanup
    exit 4
  fi
  cleanup
}

sleep_secs() {
  if [ "$1" -gt 0 ] 2>/dev/null; then
    sleep "$1"
  fi
  return 0
}

fetch_ere() {
  local out=""
  out="$("$RLR" "$1" 2>/dev/null)" || out=""
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# grep は 0=一致 / 1=不一致 / それ以外=照合不能。照合不能を不一致へ倒すと検知漏れのまま
# 送信に進むため、0 と「それ以外」を呼び分けられる形で返す(2 = 照合不能)。
# -a は不正 UTF-8 を含む pane をバイナリ扱いする grep で一致が rc=1 に化けるのを防ぐ。
match_ere() {
  local ere="$1" text="$2" rc=0
  printf '%s\n' "$text" | grep -aqiE -e "$ere" || rc=$?
  case "$rc" in
  0) return 0 ;;
  1) return 1 ;;
  *) return 2 ;;
  esac
}

capture_tail() {
  local screen=""
  screen="$("$TMUX" capture-pane -p -t "$PANE" 2>/dev/null)" || return 1
  printf '%s\n' "$screen" | tail -n 25
}

# 送信前フェンス。権限プロンプト・limit banner・pane プロセスの同一性を見る。
# 判定不能はすべて非 0(= 送らない)で返し、理由を stdout でなく変数に残す。
FENCE_REASON=""
FENCE_RC=0
send_fence() {
  local text ere rc cur_pid cur_cmd
  cur_pid="$("$TMUX" display-message -p -t "$PANE" '#{pane_pid}' 2>/dev/null || true)"
  if [ -z "$cur_pid" ]; then
    FENCE_REASON="pane-lost"; FENCE_RC=4; return 1
  fi
  if [ -n "${START_PANE_PID:-}" ] && [ "$cur_pid" != "$START_PANE_PID" ]; then
    FENCE_REASON="pane-replaced pid=$cur_pid"; FENCE_RC=4; return 1
  fi
  cur_cmd="$("$TMUX" display-message -p -t "$PANE" '#{pane_current_command}' 2>/dev/null || true)"
  # pane_pid は pane のシェルの pid なので claude が終了しても変わらない。消失を捕まえるのは
  # この cur_cmd 検査だけで、空(= 判定不能)を素通しにするとその唯一の検知が消える。
  if [ -z "$cur_cmd" ]; then
    FENCE_REASON="cmd-unreadable"; FENCE_RC=3; return 1
  fi
  # 0=シェル / 1=非シェル / それ以外=判定不能。判定不能を「非シェル」に倒すと、
  # 公開口が壊れた・版がずれた時に claude 消失の検知が黙って無効化される。
  rc=0; "$RLR" --is-shell-cmd "$cur_cmd" >/dev/null 2>&1 || rc=$?
  case "$rc" in
  0) FENCE_REASON="claude-exited cmd=$cur_cmd"; FENCE_RC=4; return 1 ;;
  1) ;;
  *) FENCE_REASON="shell-probe-failed rc=$rc"; FENCE_RC=3; return 1 ;;
  esac
  if ! text="$(capture_tail)"; then
    FENCE_REASON="capture-failed"; FENCE_RC=3; return 1
  fi
  if ! ere="$(fetch_ere --print-permission-ere)"; then
    FENCE_REASON="permission-ere-unavailable"; FENCE_RC=3; return 1
  fi
  rc=0; match_ere "$ere" "$text" || rc=$?
  case "$rc" in
  0) FENCE_REASON="permission-prompt"; FENCE_RC=3; return 1 ;;
  1) ;;
  *) FENCE_REASON="permission-match-failed"; FENCE_RC=3; return 1 ;;
  esac
  if ! ere="$(fetch_ere --print-limit-ere)"; then
    FENCE_REASON="limit-ere-unavailable"; FENCE_RC=3; return 1
  fi
  rc=0; match_ere "$ere" "$text" || rc=$?
  case "$rc" in
  0) FENCE_REASON="limited"; FENCE_RC=3; return 1 ;;
  1) ;;
  *) FENCE_REASON="limit-match-failed"; FENCE_RC=3; return 1 ;;
  esac
  return 0
}

# 0=スピナーあり / 1=無し / 2=判定不能。呼び分けるのは、idle 判定では判定不能を
# 「送らない」へ倒す一方、送信成立の確認では判定不能を「まだ成立していない」として
# 待たせたいため(同じ値に潰すとどちらかが fail-open になる)。
IDLE_REASON=""
spinner_seen() {
  local text ere rc
  ere="$(fetch_ere --print-spinner-ere)" || { IDLE_REASON="spinner-ere-unavailable"; return 2; }
  text="$(capture_tail)" || { IDLE_REASON="capture-failed"; return 2; }
  rc=0; match_ere "$ere" "$text" || rc=$?
  case "$rc" in
  0) IDLE_REASON="busy-pane"; return 0 ;;
  1) return 1 ;;
  *) IDLE_REASON="spinner-match-failed"; return 2 ;;
  esac
}

is_idle() {
  local i=1 rc
  IDLE_REASON=""
  while [ "$i" -le "$IDLE_CHECKS" ]; do
    rc=0; spinner_seen || rc=$?
    if [ "$rc" -ne 1 ]; then
      return 1
    fi
    if [ "$i" -lt "$IDLE_CHECKS" ]; then
      sleep_secs "$IDLE_INTERVAL"
    fi
    i=$((i + 1))
  done
  return 0
}

# literal と Enter は 2 段なので、その間にもフェンスを通す。ここで権限プロンプトが出ると
# Enter は既定選択の確定 = 代理承認になる。止めた場合 literal は入力欄に残るので、
# フェンスの rc に依らず人間へ返す(rc=3 は「次周期に再試行してよい」なので、残留の上へ
# 次周期がもう 1 本積んで Enter を押す。送っていない文字列を人間が消すまで代行を止める)。
send_line() {
  local label="$1" text="$2"
  "$TMUX" send-keys -t "$PANE" -l "$text" || finish 4 "send-failed cmd=$label"
  sleep_secs "$SEND_DELAY"
  send_fence || finish 4 "$FENCE_REASON literal-pending=$label"
  own_lock || finish 4 "lock-lost literal-pending=$label"
  "$TMUX" send-keys -t "$PANE" Enter || finish 4 "send-failed cmd=$label-enter"
  return 0
}

# ロック所有の再確認。stale 奪取をしない設計でも、trap 未実行死 → 人間が消す →
# 別プロセスが取得、の順で自分の所有が失われた状態で送るのを防ぐ。
own_lock() {
  local pid
  pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
  [ "$pid" = "$$" ]
}

STATUS_ONLY=0
if [ "${1:-}" = "--status" ]; then
  STATUS_ONLY=1
  if [ "$#" -ne 2 ]; then
    echo "Usage: $PROG --status <worktree>" >&2
    exit 1
  fi
  WORKTREE="$2"
else
  if [ "$#" -ne 2 ]; then
    echo "Usage: $PROG <pane_id> <worktree>  |  $PROG --status <worktree>" >&2
    exit 1
  fi
  PANE="$1"
  PANE_LABEL="$1"
  WORKTREE="$2"
  case "$PANE" in
  %[0-9]*) ;;
  *) echo "pane_id が %NN 形でない: $PANE" >&2; exit 1 ;;
  esac
fi

case "$WORKTREE" in
/*) ;;
*) echo "worktree は絶対パスで渡す: $WORKTREE" >&2; exit 1 ;;
esac
WORKTREE="${WORKTREE%/}"

command -v jq >/dev/null 2>&1 || finish 4 "jq-missing"
[ -r "$CTX_LIB" ] || finish 4 "ctx-lib-unreachable"

# 数値パラメータは使う前にまとめて検証する。非数値だと `[` が rc=2 を返すが、
# while の条件など set -e が効かない位置では判定を素通りする(idle 判定が丸ごと飛ぶ)。
for _v in THRESHOLD IDLE_CHECKS IDLE_INTERVAL SEND_ACK_TIMEOUT \
  PREP_TIMEOUT COMPACT_TIMEOUT SEND_DELAY SCAN_LINES; do
  case "${!_v:-}" in
  '' | *[!0-9]*) finish 4 "bad-env ACD_${_v}=${!_v:-}" ;;
  esac
done
[ "$IDLE_CHECKS" -ge 1 ] || finish 4 "bad-env ACD_IDLE_CHECKS=$IDLE_CHECKS"
[ "$SCAN_LINES" -ge 1 ] || finish 4 "bad-env ACD_SCAN_LINES=$SCAN_LINES"

# ハンドラはロック取得より前に張る。ロック分岐の内側だと --status とロック取得前の区間が
# 素通しになり、その区間の中断で終端行が 1 行も出ない。ハンドラは finish を通す
# (cleanup だけだと解錠したまま本体が走り続け、ロック無しで送信する経路ができる)。
# rc は表に載っている 4(人間が要る)に寄せる(130/143 は運転元が知らない値になる)。
# 背景 1 本で起動する設計なので、運転元 pane の終了に伴う HUP も拾う(拾わないと解錠されず、
# 奪取しない設計のためその pane の代行が stale-lock で恒久的に止まる)。
trap 'on_exit' EXIT
trap 'finish 4 "interrupted"' INT
trap 'finish 4 "terminated"' TERM
trap 'finish 4 "hangup"' HUP

if [ "$STATUS_ONLY" -eq 0 ]; then
  SELF_PANE="${TMUX_PANE:-${ACD_SELF_PANE:-}}"
  [ -n "$SELF_PANE" ] || finish 4 "self-pane-unknown"
  [ "$SELF_PANE" != "$PANE" ] || finish 4 "self-pane"

  lock_dir="${TMPDIR:-/tmp}"
  lock_dir="${lock_dir%/}"
  lock_key="$(printf '%s' "$PANE" | tr -c 'A-Za-z0-9._-' '_')"
  LOCK="$lock_dir/claude-acd-$lock_key.lock"
  if mkdir "$LOCK" 2>/dev/null; then
    LOCK_OWNED=1
    printf '%s' "$$" >"$LOCK/pid"
  else
    holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
    case "$holder" in
    '' | *[!0-9]*) finish 4 "stale-lock lock=$LOCK" ;;
    esac
    if kill -0 "$holder" 2>/dev/null; then
      finish 3 "busy pid=$holder"
    fi
    # 奪取は原子的にできない(読む → 死亡判定 → 消す → mkdir の間に別プロセスが同じ判断をする)。
    # 二重送信を防ぐのがこのロックの目的なので、奪わずに人間へ返す。
    finish 4 "stale-lock lock=$LOCK pid=$holder"
  fi
fi

CACHE_BASE="$("$CTX_LIB" base 2>/dev/null)" || CACHE_BASE=""
[ -n "$CACHE_BASE" ] || finish 4 "cache-base-unresolved"
LIB_STALE="$("$CTX_LIB" stale-secs 2>/dev/null)" || LIB_STALE=""
STALE_SECS="${ACD_STALE_SECS:-$LIB_STALE}"
case "$STALE_SECS" in
'' | *[!0-9]*) finish 4 "stale-secs-unresolved" ;;
esac

now="$(date +%s)"
ctx=""
ctx_pct=""
match_count=0
for usage_file in "$CACHE_BASE"/*/usage.json; do
  [ -f "$usage_file" ] || continue
  updated="$(jq -r '.updated_at // empty' "$usage_file" 2>/dev/null || true)"
  case "$updated" in
  '' | *[!0-9]*) continue ;;
  esac
  [ "$((now - updated))" -le "$STALE_SECS" ] || continue
  transcript="$(jq -r '.transcript_path // empty' "$usage_file" 2>/dev/null || true)"
  case "$transcript" in
  "$HOME/.claude/projects/"*) ;;
  *) continue ;;
  esac
  [ -f "$transcript" ] || continue
  # 末尾行は last-prompt / agent-name 等で cwd を持たないことが多い(実測)。数行遡って
  # cwd を持つ最後のレコードを採る。fromjson? で壊れた行・非 JSON 行は黙って捨てる。
  cwd="$(tail -n "$SCAN_LINES" "$transcript" | jq -rR 'fromjson? | objects | .cwd // empty' 2>/dev/null | tail -n 1 || true)"
  [ -n "$cwd" ] || continue
  [ "${cwd%/}" = "$WORKTREE" ] || continue
  match_count=$((match_count + 1))
  ctx="$(basename "$(dirname "$usage_file")")"
  ctx_pct="$(jq -r '.pct // empty' "$usage_file" 2>/dev/null || true)"
done

[ "$match_count" -le 1 ] || finish 4 "ambiguous matches=$match_count worktree=$WORKTREE"
[ "$match_count" -eq 1 ] || finish 2 "no-ctx worktree=$WORKTREE"

case "$ctx_pct" in
'' | *[!0-9.]*) finish 2 "pct-unreadable ctx=$ctx" ;;
esac
pct_int="${ctx_pct%%.*}"
case "$pct_int" in
'' | *[!0-9]*) finish 2 "pct-unreadable ctx=$ctx" ;;
esac

emit "ctx=$ctx pct=$pct_int threshold=$THRESHOLD"
[ "$pct_int" -ge "$THRESHOLD" ] || finish 2 "low-pct pct=$pct_int ctx=$ctx"
[ "$STATUS_ONLY" -eq 0 ] || finish 0 "ready pct=$pct_int ctx=$ctx"

STATE_FILE="$("$CTX_LIB" state "$ctx" 2>/dev/null)" || STATE_FILE=""
COMPACTED_MARKER="$("$CTX_LIB" compacted "$ctx" 2>/dev/null)" || COMPACTED_MARKER=""
[ -n "$STATE_FILE" ] || finish 4 "state-path-unresolved ctx=$ctx"
[ -n "$COMPACTED_MARKER" ] || finish 4 "marker-path-unresolved ctx=$ctx"

START_PANE_PID="$("$TMUX" display-message -p -t "$PANE" '#{pane_pid}' 2>/dev/null || true)"
[ -n "$START_PANE_PID" ] || finish 4 "pane-lost"

# フェンスは送信の直前に置く。idle 判定は間隔を空けて複数回見るので、フェンスを先に
# 置くと権限プロンプトの検査が送信の数秒前の観測になる。しかもプロンプト表示中は
# スピナーが消えるため idle 判定はそれを idle と読む(その窓で出たプロンプトを誰も見ない)。
is_idle || finish 3 "${IDLE_REASON:-busy-pane}"
send_fence || finish "$FENCE_RC" "$FENCE_REASON"

BASELINE="$(mktemp "${TMPDIR:-/tmp}/claude-acd-baseline.XXXXXX")" || finish 4 "baseline-failed"

own_lock || finish 4 "lock-lost"
send_line prep '/compact-prep'
emit "sent /compact-prep ctx=$ctx"

# 送信の成立は「正の signal」で確認する。送信に成功した文字列も会話領域にエコーとして
# 残るため、画面から文字列が消えたかでは成功と失敗を区別できない(tmux-claude-drive 手順 3 の
# 2026-07-18 実測知)。スピナー出現、または state file の更新を成立と見なす。
# 実測(2026-07-27、捨て pane): send-keys -l '/compact' で補完リストが開くが Enter は
# 食われず、入力した文字列がそのまま実行される(前方一致のより長い候補があっても完全一致が優先)。
prep_ack=0
retried=0
while :; do
  waited=0
  while [ "$waited" -lt "$SEND_ACK_TIMEOUT" ]; do
    ack_rc=0; spinner_seen || ack_rc=$?
    if [ "$ack_rc" -eq 0 ]; then
      prep_ack=1
      break
    fi
    if [ -f "$STATE_FILE" ] && [ "$STATE_FILE" -nt "$BASELINE" ]; then
      prep_ack=1
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if [ "$prep_ack" -eq 1 ] || [ "$retried" -eq 1 ]; then
    break
  fi
  retried=1
  emit "prep-ack-retry"
  # 裸の Enter も送信。ack が取れない代表的な原因は「送信後に権限プロンプトが出た」で、
  # その状態の Enter は既定選択の確定 = 代理承認になる。他 2 経路と同じフェンスを通す。
  send_fence || finish "$FENCE_RC" "$FENCE_REASON"
  own_lock || finish 4 "lock-lost"
  "$TMUX" send-keys -t "$PANE" Enter || finish 4 "send-failed cmd=prep-retry"
done
[ "$prep_ack" -eq 1 ] || finish 4 "prep-not-started ctx=$ctx"

waited=0
prep_done=0
while [ "$waited" -lt "$PREP_TIMEOUT" ]; do
  if is_idle; then
    prep_done=1
    break
  fi
  sleep 1
  waited=$((waited + 1))
done
[ "$prep_done" -eq 1 ] || finish 4 "prep-timeout ctx=$ctx"

[ -f "$STATE_FILE" ] || finish 4 "state-missing ctx=$ctx"
[ "$STATE_FILE" -nt "$BASELINE" ] || finish 4 "state-not-written ctx=$ctx"
# mtime だけで送ると、壊れた state のまま /compact して precompact-gate の 1 回限りの
# ブロックを消費し、次に人間が手で打つ /compact が素通しになる。gate と同じ検証器を通す。
if [ -x "$VALIDATE_STATE" ] || [ -r "$VALIDATE_STATE" ]; then
  bash "$VALIDATE_STATE" "$STATE_FILE" >/dev/null 2>&1 || finish 4 "state-invalid ctx=$ctx"
else
  finish 4 "validator-unreachable ctx=$ctx"
fi

send_fence || finish "$FENCE_RC" "$FENCE_REASON"
own_lock || finish 4 "lock-lost"
send_line compact '/compact'
emit "sent /compact ctx=$ctx"

waited=0
while [ "$waited" -lt "$COMPACT_TIMEOUT" ]; do
  if [ -f "$COMPACTED_MARKER" ] && [ "$COMPACTED_MARKER" -nt "$BASELINE" ]; then
    finish 0 "compacted ctx=$ctx"
  fi
  sleep 1
  waited=$((waited + 1))
done
finish 4 "compact-not-confirmed ctx=$ctx"
