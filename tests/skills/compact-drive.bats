#!/usr/bin/env bats
# tmux-claude-drive 付属の compact-drive.sh(compact 代行)の送信可否判定を固定する。
#
# tmux は ACD_TMUX で fake に差し替える(実 tmux に触れない)。fake は
#   $FAKE_SCREEN  … capture-pane が返す画面テキスト
#   $FAKE_PID     … pane_pid / $FAKE_CMD … pane_current_command
#   $FAKE_SENT    … send-keys -l の送信文字列と Enter を追記(送信回数と順序の検証用)
# を参照し、`/compact-prep` / `/compact` の送信を観測したら、被運転側の副作用
# (state file の書き出し・PostCompact marker)を fixture として再現する。
#
# 検証の主眼は「送ってはいけない状態で送らないこと」。各ケースは exit code と
# 送信ログの両方を見る(exit code だけだと送信済みの取り逃しに気付けない)。
#
# 注: mtime 比較(-nt)は秒粒度なので、fixture 側で touch -A により mtime を明示的に
# 進める(同一秒に作ると -nt が偽になり、鮮度判定ケースが意図と逆に転ぶ)。

load ../helpers/common

setup() {
  install_hooks
  install_skill_scripts
  SCRIPT="$HOME/.claude/skills/tmux-claude-drive/scripts/compact-drive.sh"

  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"

  WORKTREE="$BATS_TEST_TMPDIR/wt"
  mkdir -p "$WORKTREE"

  PROJECTS="$HOME/.claude/projects/-p"
  mkdir -p "$PROJECTS"

  export FAKE_SCREEN="$BATS_TEST_TMPDIR/screen"
  export FAKE_PID="$BATS_TEST_TMPDIR/pid"
  export FAKE_CMD="$BATS_TEST_TMPDIR/cmd"
  export FAKE_SENT="$BATS_TEST_TMPDIR/sent"
  export FAKE_STATE_ON_PREP=""
  export FAKE_MARKER_ON_COMPACT=""
  export FAKE_PID_AFTER=""
  export FAKE_PIDCOUNT="$BATS_TEST_TMPDIR/pidcount"
  export FAKE_CAPCOUNT="$BATS_TEST_TMPDIR/capcount"
  export FAKE_SCREEN_AFTER="$BATS_TEST_TMPDIR/screen-after"
  export FAKE_SCREEN_SWITCH_AT=""
  export FAKE_STEAL_LOCK_ON_PREP=""
  printf 'ready\n' >"$FAKE_SCREEN_AFTER"
  printf 'ready\n' >"$FAKE_SCREEN"
  printf '100' >"$FAKE_PID"
  printf 'node' >"$FAKE_CMD"
  : >"$FAKE_SENT"

  FAKE="$BATS_TEST_TMPDIR/faketmux"
  cat >"$FAKE" <<'EOF'
#!/usr/bin/env bash
sub="$1"; shift
case "$sub" in
display-message)
  last=""
  for a in "$@"; do last="$a"; done
  case "$last" in
  '#{pane_pid}')
    n="$(cat "$FAKE_PIDCOUNT" 2>/dev/null || echo 0)"
    n=$((n + 1))
    printf '%s' "$n" >"$FAKE_PIDCOUNT"
    # 2 回目以降だけ別 PID を返す = 起動後に pane が別プロセスへ置き換わった状況
    if [ -n "$FAKE_PID_AFTER" ] && [ "$n" -gt 1 ]; then
      printf '%s' "$FAKE_PID_AFTER"
    else
      cat "$FAKE_PID"
    fi
    ;;
  '#{pane_current_command}') cat "$FAKE_CMD" ;;
  esac
  ;;
capture-pane)
  if [ -f "$FAKE_SCREEN.fail" ]; then exit 1; fi
  n="$(cat "$FAKE_CAPCOUNT" 2>/dev/null || echo 0)"
  n=$((n + 1))
  printf '%s' "$n" >"$FAKE_CAPCOUNT"
  # N 回目以降だけ画面を差し替える = 判定の途中で pane の状態が変わる状況
  if [ -n "$FAKE_SCREEN_SWITCH_AT" ] && [ "$n" -ge "$FAKE_SCREEN_SWITCH_AT" ]; then
    cat "$FAKE_SCREEN_AFTER"
  else
    cat "$FAKE_SCREEN"
  fi
  ;;
send-keys)
  prev=""; literal=""
  for a in "$@"; do
    if [ "$prev" = "-l" ]; then literal="$a"; fi
    if [ "$a" = "Enter" ]; then printf 'ENTER\n' >>"$FAKE_SENT"; fi
    prev="$a"
  done
  if [ -n "$literal" ]; then
    printf '%s\n' "$literal" >>"$FAKE_SENT"
    case "$literal" in
    /compact-prep)
      if [ -n "$FAKE_STATE_ON_PREP" ]; then
        cp "$FAKE_STATE_ON_PREP" "$FAKE_STATE_DST"
        touch -A 000010 "$FAKE_STATE_DST"
      fi
      # 送信を観測した時点でロックの持ち主が他へ変わる状況(所有権喪失)
      if [ -n "$FAKE_STEAL_LOCK_ON_PREP" ]; then
        printf '%s' 1 >"$FAKE_STEAL_LOCK_ON_PREP/pid"
      fi
      ;;
    /compact)
      if [ -n "$FAKE_MARKER_ON_COMPACT" ]; then
        : >"$FAKE_MARKER_ON_COMPACT"
        touch -A 000010 "$FAKE_MARKER_ON_COMPACT"
      fi
      ;;
    esac
  fi
  ;;
esac
exit 0
EOF
  chmod +x "$FAKE"
  export ACD_TMUX="$FAKE"

  export ACD_IDLE_INTERVAL=0
  export ACD_SEND_DELAY=0
  export ACD_SEND_ACK_TIMEOUT=2
  export ACD_PREP_TIMEOUT=3
  export ACD_COMPACT_TIMEOUT=3
  # 自 pane と対象 pane を別にする。bats 自体が tmux 内で走ると TMUX_PANE が
  # 継承され、対象と一致した瞬間に全ケースが self-pane で落ちる。
  export TMUX_PANE="%99"
}

# make_ctx <ctx> <pct> <cwd> [updated_at_offset_secs]
make_ctx() {
  local ctx="$1" pct="$2" cwd="$3" age="${4:-0}"
  local dir="$XDG_CACHE_HOME/claude-context/$ctx"
  mkdir -p "$dir"
  local transcript="$PROJECTS/$ctx.jsonl"
  {
    printf '{"type":"assistant","cwd":"%s"}\n' "$cwd"
    printf '{"type":"last-prompt","prompt":"x"}\n'
  } >"$transcript"
  local now updated
  now="$(date +%s)"
  updated=$((now - age))
  printf '{"pct":%s,"transcript_path":"%s","updated_at":%s}\n' "$pct" "$transcript" "$updated" >"$dir/usage.json"
  export FAKE_STATE_DST="$dir/state.md"
  MARKER="$dir/compacted"
}

valid_state() {
  local f="$BATS_TEST_TMPDIR/state-valid.md"
  cat >"$f" <<'EOF'
# state file

## Active Plan
なし

## Session Decisions
なし

## Constraints and Blockers
なし

## Worker Topology
なし

## Editing Files
なし
EOF
  printf '%s' "$f"
}

broken_state() {
  local f="$BATS_TEST_TMPDIR/state-broken.md"
  printf '# state file\n\n## Active Plan\n\n' >"$f"
  printf '%s' "$f"
}

sent_count() {
  grep -c "^$1\$" "$FAKE_SENT" || true
}

# 送信ログが完全に空であることを見る。ENTER を除外して数えると「裸の Enter だけ送る」
# 経路(= 権限プロンプトの既定選択を確定させる形)を送信ゼロと誤判定する。
assert_no_send() {
  if [ -s "$FAKE_SENT" ]; then
    echo "unexpected send: $(cat "$FAKE_SENT")"
    return 1
  fi
}

@test "low usage: does not send" {
  make_ctx ctx1 12 "$WORKTREE"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 2 ]
  assert_no_send
  case "$output" in *"low-pct"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "stale usage file: does not send" {
  make_ctx ctx1 80 "$WORKTREE" 5000
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 2 ]
  assert_no_send
  case "$output" in *"no-ctx"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "no matching worktree: exits 2 without sending" {
  make_ctx ctx1 80 "/some/other/worktree"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 2 ]
  assert_no_send
}

@test "cwd found several lines above the tail is still resolved" {
  make_ctx ctx1 80 "$WORKTREE"
  # 末尾行が cwd を持たない実測形。数行遡って拾えることを固定する。
  {
    printf '{"type":"assistant","cwd":"%s"}\n' "$WORKTREE"
    printf '{"type":"agent-name","name":"x"}\n'
    printf '{"type":"permission-mode","mode":"auto"}\n'
    printf '{"type":"last-prompt","prompt":"x"}\n'
  } >"$PROJECTS/ctx1.jsonl"
  FAKE_STATE_ON_PREP="$(valid_state)"
  FAKE_MARKER_ON_COMPACT="$MARKER"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 0 ]
}

@test "two contexts on one worktree: escalates without sending" {
  make_ctx ctx1 80 "$WORKTREE"
  make_ctx ctx2 80 "$WORKTREE"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 4 ]
  assert_no_send
  case "$output" in *"ambiguous"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "permission prompt on screen: does not send" {
  make_ctx ctx1 80 "$WORKTREE"
  printf 'Do you want to proceed?\n> 1. Yes\n' >"$FAKE_SCREEN"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 3 ]
  assert_no_send
  case "$output" in *"permission-prompt"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "unreachable ERE port: does not send" {
  make_ctx ctx1 80 "$WORKTREE"
  rm -f "$HOME/.claude/skills/tmux-claude-drive/scripts/rate-limit-resume.sh"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 3 ]
  assert_no_send
}

@test "capture failure: does not send" {
  make_ctx ctx1 80 "$WORKTREE"
  : >"$FAKE_SCREEN.fail"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 3 ]
  assert_no_send
  case "$output" in *"capture-failed"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "rate limited pane: does not send" {
  make_ctx ctx1 80 "$WORKTREE"
  # 検知語そのものは fixture にだけ置く(コメントへ書き写すと監視側の誤検知を誘う)
  printf 'Claude %s limit reached\n' "usage" >"$FAKE_SCREEN"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 3 ]
  assert_no_send
}

@test "busy pane: does not send" {
  make_ctx ctx1 80 "$WORKTREE"
  printf 'Thinking... (12s %s esc to interrupt)\n' "·" >"$FAKE_SCREEN"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 3 ]
  assert_no_send
  case "$output" in *"busy-pane"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "state file not written by prep: sends prep only" {
  make_ctx ctx1 80 "$WORKTREE"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 4 ]
  [ "$(sent_count '/compact-prep')" -eq 1 ]
  [ "$(sent_count '/compact')" -eq 0 ]
}

@test "state file fails structure validation: does not send compact" {
  make_ctx ctx1 80 "$WORKTREE"
  FAKE_STATE_ON_PREP="$(broken_state)"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 4 ]
  [ "$(sent_count '/compact-prep')" -eq 1 ]
  [ "$(sent_count '/compact')" -eq 0 ]
  case "$output" in *"state-invalid"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "happy path: prep then compact, confirmed by marker" {
  make_ctx ctx1 80 "$WORKTREE"
  FAKE_STATE_ON_PREP="$(valid_state)"
  FAKE_MARKER_ON_COMPACT="$MARKER"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$(sent_count '/compact-prep')" -eq 1 ]
  [ "$(sent_count '/compact')" -eq 1 ]
  # 順序: prep が先、compact が後
  first="$(grep -v '^ENTER$' "$FAKE_SENT" | head -n 1)"
  [ "$first" = "/compact-prep" ]
  case "$output" in *"done rc=0 reason=compacted"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "marker never appears: escalates after sending compact" {
  make_ctx ctx1 80 "$WORKTREE"
  FAKE_STATE_ON_PREP="$(valid_state)"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 4 ]
  [ "$(sent_count '/compact')" -eq 1 ]
  case "$output" in *"compact-not-confirmed"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "target pane equals own pane: refuses" {
  make_ctx ctx1 80 "$WORKTREE"
  TMUX_PANE="%5" run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 4 ]
  assert_no_send
  case "$output" in *"self-pane"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "own pane unknown: refuses" {
  make_ctx ctx1 80 "$WORKTREE"
  run env -u TMUX_PANE -u ACD_SELF_PANE bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 4 ]
  assert_no_send
  case "$output" in *"self-pane-unknown"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "lock held by a live process: retryable, no send" {
  make_ctx ctx1 80 "$WORKTREE"
  lock="$TMPDIR/claude-acd-_5.lock"
  mkdir -p "$lock"
  printf '%s' "$$" >"$lock/pid"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 3 ]
  assert_no_send
  case "$output" in *"busy pid="*) ;; *) echo "$output"; return 1 ;; esac
}

@test "stale lock is not stolen: escalates" {
  make_ctx ctx1 80 "$WORKTREE"
  lock="$TMPDIR/claude-acd-_5.lock"
  mkdir -p "$lock"
  # 存在しない PID(取得済みで死亡した前回の残骸)
  printf '%s' 999999 >"$lock/pid"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 4 ]
  assert_no_send
  case "$output" in *"stale-lock"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "lock is released on success" {
  make_ctx ctx1 80 "$WORKTREE"
  FAKE_STATE_ON_PREP="$(valid_state)"
  FAKE_MARKER_ON_COMPACT="$MARKER"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 0 ]
  [ ! -d "$TMPDIR/claude-acd-_5.lock" ]
}

@test "pane process replaced: refuses" {
  make_ctx ctx1 80 "$WORKTREE"
  FAKE_PID_AFTER=777 run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 4 ]
  assert_no_send
  case "$output" in *"pane-replaced"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "shell in front of the pane: refuses" {
  make_ctx ctx1 80 "$WORKTREE"
  printf 'zsh' >"$FAKE_CMD"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 4 ]
  assert_no_send
  case "$output" in *"claude-exited"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "pane gone: refuses" {
  make_ctx ctx1 80 "$WORKTREE"
  : >"$FAKE_PID"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 4 ]
  assert_no_send
  case "$output" in *"pane-lost"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "signal file records events and the terminal line" {
  make_ctx ctx1 12 "$WORKTREE"
  sig="$BATS_TEST_TMPDIR/sig"
  ACD_SIGNAL_FILE="$sig" run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 2 ]
  grep -q "^ACD: pane=%5 " "$sig"
  grep -q "done rc=2 reason=low-pct" "$sig"
}

@test "status mode reports without sending" {
  make_ctx ctx1 80 "$WORKTREE"
  run bash "$SCRIPT" --status "$WORKTREE"
  [ "$status" -eq 0 ]
  assert_no_send
  case "$output" in *"ready pct=80"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "status mode shares the reason vocabulary with the send path" {
  make_ctx ctx1 12 "$WORKTREE"
  run bash "$SCRIPT" --status "$WORKTREE"
  [ "$status" -eq 2 ]
  case "$output" in *"low-pct"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "jq missing: refuses without sending" {
  make_ctx ctx1 80 "$WORKTREE"
  shim="$(make_no_jq_path)"
  PATH="$shim" run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 4 ]
  assert_no_send
  case "$output" in *"jq-missing"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "permission prompt appearing after the idle checks: does not send" {
  make_ctx ctx1 80 "$WORKTREE"
  printf 'Do you want to proceed?\n> 1. Yes\n' >"$FAKE_SCREEN_AFTER"
  # idle 判定の 2 回分は ready、その後にプロンプトが出る。フェンスが送信の直前に
  # 無いと、この窓で出たプロンプトを誰も見ないまま送ってしまう。
  FAKE_SCREEN_SWITCH_AT=3 run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 3 ]
  assert_no_send
  [ "$(grep -c '^ENTER$' "$FAKE_SENT" || true)" -eq 0 ]
}

@test "prompt between the literal and Enter: Enter is withheld and rc goes to the human" {
  make_ctx ctx1 80 "$WORKTREE"
  printf 'Do you want to proceed?\n> 1. Yes\n' >"$FAKE_SCREEN_AFTER"
  # literal 投入から Enter までの間にプロンプトが出た状況。ここで Enter を送ると
  # 既定選択の確定 = 代理承認になる。literal は入力欄に残るので、rc=3(次周期に
  # 再試行してよい)で返すと次周期が残留へもう 1 本積んで Enter を押す。
  FAKE_SCREEN_SWITCH_AT=4 run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 4 ]
  [ "$(sent_count '/compact-prep')" -eq 1 ]
  [ "$(grep -c '^ENTER$' "$FAKE_SENT" || true)" -eq 0 ]
  case "$output" in *"literal-pending=prep"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "prep ack retry passes the fence before sending Enter" {
  make_ctx ctx1 80 "$WORKTREE"
  printf 'Do you want to proceed?\n> 1. Yes\n' >"$FAKE_SCREEN_AFTER"
  # prep が送信された後にプロンプトが出た状況。ack が取れずリトライ経路に入るが、
  # そこで裸の Enter を送ると既定選択の確定 = 代理承認になる。
  FAKE_SCREEN_SWITCH_AT=5 run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 3 ]
  [ "$(sent_count '/compact-prep')" -eq 1 ]
  # send_line の 1 回だけ。リトライの Enter が増えていないこと
  [ "$(grep -c '^ENTER$' "$FAKE_SENT" || true)" -eq 1 ]
}

@test "pane command unreadable: does not send" {
  make_ctx ctx1 80 "$WORKTREE"
  : >"$FAKE_CMD"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 3 ]
  assert_no_send
  case "$output" in *"cmd-unreadable"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "permission prompt before the compact send: does not send compact" {
  make_ctx ctx1 80 "$WORKTREE"
  FAKE_STATE_ON_PREP="$(valid_state)"
  printf 'Do you want to proceed?\n> 1. Yes\n' >"$FAKE_SCREEN_AFTER"
  # prep 完了確認までは ready、/compact 直前のフェンスでプロンプトを見る
  FAKE_SCREEN_SWITCH_AT=7 run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 3 ]
  [ "$(sent_count '/compact-prep')" -eq 1 ]
  [ "$(sent_count '/compact')" -eq 0 ]
}

@test "lock taken over by another process: keeps that lock and stops" {
  make_ctx ctx1 80 "$WORKTREE"
  FAKE_STATE_ON_PREP="$(valid_state)"
  lock="$TMPDIR/claude-acd-_5.lock"
  FAKE_STEAL_LOCK_ON_PREP="$lock" run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 4 ]
  case "$output" in *"lock-lost"*) ;; *) echo "$output"; return 1 ;; esac
  # ロックを失った状態で Enter を送らないこと(この検査が send_line の own_lock の存在意義)
  [ "$(grep -c '^ENTER$' "$FAKE_SENT" || true)" -eq 0 ]
  # 他プロセスの所有になったロックを消さないこと(消すと二重送信の窓が開く)
  [ -d "$lock" ]
  [ "$(cat "$lock/pid")" = "1" ]
}

@test "non-numeric ACD_IDLE_CHECKS is rejected instead of skipping the idle check" {
  make_ctx ctx1 80 "$WORKTREE"
  printf 'Thinking... (12s %s esc to interrupt)\n' "·" >"$FAKE_SCREEN"
  ACD_IDLE_CHECKS=abc run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 4 ]
  assert_no_send
  case "$output" in *"bad-env"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "zero ACD_IDLE_CHECKS is rejected instead of skipping the idle check" {
  make_ctx ctx1 80 "$WORKTREE"
  printf 'Thinking... (12s %s esc to interrupt)\n' "·" >"$FAKE_SCREEN"
  # 0 だと while が 1 度も回らず「スピナー未確認のまま idle」になる。
  # 非数値とは別の行が守っているので、別ケースで固定する。
  ACD_IDLE_CHECKS=0 run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 4 ]
  assert_no_send
  case "$output" in *"bad-env"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "permission ERE port returning nothing stops the send" {
  make_ctx ctx1 80 "$WORKTREE"
  # spinner ERE は返せるが権限プロンプト ERE を返せない版。idle 判定は通るので、
  # 送信フェンス側の取得失敗が fail-closed であることだけを固定できる。
  stub="$HOME/.claude/skills/tmux-claude-drive/scripts/rate-limit-resume.sh"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
--print-spinner-ere) printf '%s\n' '[0-9]+s[[:space:]]*·' ;;
--print-permission-ere) : ;;
--print-limit-ere) printf '%s\n' 'usage limit' ;;
--is-shell-cmd) exit 1 ;;
esac
STUB
  chmod +x "$stub"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 3 ]
  assert_no_send
  case "$output" in *"permission-ere-unavailable"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "usage percentage exactly at the line is treated as reached" {
  make_ctx ctx1 40 "$WORKTREE"
  FAKE_STATE_ON_PREP="$(valid_state)"
  FAKE_MARKER_ON_COMPACT="$MARKER"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 0 ]
}

@test "usage percentage just below the line does not send" {
  make_ctx ctx1 39 "$WORKTREE"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 2 ]
  assert_no_send
}

@test "ACD_THRESHOLD overrides the default line" {
  make_ctx ctx1 45 "$WORKTREE"
  ACD_THRESHOLD=50 run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 2 ]
  assert_no_send
  case "$output" in *"low-pct"*) ;; *) echo "$output"; return 1 ;; esac
}

@test "shell-cmd probe that cannot answer stops the send" {
  make_ctx ctx1 80 "$WORKTREE"
  # ERE は返せるが --is-shell-cmd に答えられない版(版ずれ)を模す
  stub="$HOME/.claude/skills/tmux-claude-drive/scripts/rate-limit-resume.sh"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
--print-permission-ere) printf '%s\n' 'do you want to' ;;
--print-limit-ere) printf '%s\n' 'usage limit' ;;
--print-spinner-ere) printf '%s\n' '[0-9]+s[[:space:]]*·' ;;
*) exit 127 ;;
esac
STUB
  chmod +x "$stub"
  run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 3 ]
  assert_no_send
}

@test "relative worktree argument is rejected" {
  run bash "$SCRIPT" "%5" "relative/path"
  [ "$status" -eq 1 ]
  assert_no_send
}

@test "malformed pane id is rejected" {
  run bash "$SCRIPT" "sess:win.0" "$WORKTREE"
  [ "$status" -eq 1 ]
  assert_no_send
}

# 終端契約(rc 表の値と実 exit status を必ず揃える)。回収路は signal file と exit status の
# 2 系統あるので、片方だけ rc=4 になると運転元の判断が割れる。
@test "set -e abort exits with the rc it reported" {
  make_ctx ctx1 80 "$WORKTREE"
  shim="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$shim"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$shim/date"
  chmod +x "$shim/date"
  sig="$BATS_TEST_TMPDIR/sig"
  PATH="$shim:$PATH" ACD_SIGNAL_FILE="$sig" run bash "$SCRIPT" "%5" "$WORKTREE"
  [ "$status" -eq 4 ]
  assert_no_send
  grep -q 'done rc=4 reason=aborted' "$sig"
}

@test "status mode: a signal before the lock still leaves the terminal line" {
  make_ctx ctx1 80 "$WORKTREE"
  # ロック取得は非 status 経路にしか無いので、その手前の区間で中断させる
  cat >"$HOME/.claude/hooks/lib/context-paths.sh" <<'STUB'
#!/usr/bin/env bash
sleep 3
STUB
  chmod +x "$HOME/.claude/hooks/lib/context-paths.sh"
  sig="$BATS_TEST_TMPDIR/sig"
  ACD_SIGNAL_FILE="$sig" bash "$SCRIPT" --status "$WORKTREE" &
  pid=$!
  sleep 1
  kill -TERM "$pid"
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 4 ]
  grep -q 'done rc=4 reason=terminated' "$sig"
}

@test "hangup releases the lock and reports through the rc table" {
  make_ctx ctx1 80 "$WORKTREE"
  cat >"$HOME/.claude/hooks/lib/context-paths.sh" <<'STUB'
#!/usr/bin/env bash
sleep 3
STUB
  chmod +x "$HOME/.claude/hooks/lib/context-paths.sh"
  sig="$BATS_TEST_TMPDIR/sig"
  ACD_SIGNAL_FILE="$sig" bash "$SCRIPT" "%5" "$WORKTREE" &
  pid=$!
  sleep 1
  kill -HUP "$pid"
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 4 ]
  grep -q 'done rc=4 reason=hangup' "$sig"
  # 解錠しないと以降その pane は stale-lock で恒久的に止まる
  [ ! -d "$TMPDIR/claude-acd-_5.lock" ]
}
