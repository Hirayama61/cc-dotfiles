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
  cat "$FAKE_SCREEN"
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

assert_no_send() {
  local n
  n="$(grep -cv '^ENTER$' "$FAKE_SENT" || true)"
  if [ "$n" -ne 0 ]; then
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
