#!/usr/bin/env bats
# dev-pipeline の rate-limit-resume.sh の状態機械を固定する(Plan v2 §2.3 / §7.4)。
#
# tmux は RLR_TMUX で fake に差し替える(実 tmux に触れない)。fake は stateful:
# capture-pane 呼び出しごとにステップカウンタを進め、各ステップの
# pane_current_command / pane_pid / 画面テキストを $STEPDIR/<n>.{cmd,pid,txt} から返す。
# send-keys -l の送信フレーズは $SENT に記録し、送信回数を検証する。
#
# 検証ケース: 明け→単回送信で resumed / 権限プロンプトでは送信しない / claude 消失で
# 経路 B / pane 置換で経路 B / ack 失敗時の再送上限。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/home/dot_claude/skills/dev-pipeline/scripts/executable_rate-limit-resume.sh"

  STEPDIR="$BATS_TEST_TMPDIR/steps"
  mkdir -p "$STEPDIR"
  SENT="$BATS_TEST_TMPDIR/sent"
  COUNT="$BATS_TEST_TMPDIR/count"
  : >"$SENT"
  echo 0 >"$COUNT"

  FAKE="$BATS_TEST_TMPDIR/faketmux"
  cat >"$FAKE" <<'EOF'
#!/usr/bin/env bash
sub="$1"; shift
last=""
for a in "$@"; do last="$a"; done
count="$(cat "$FAKE_COUNT" 2>/dev/null || echo 0)"
case "$sub" in
display-message)
  case "$last" in
  '#{pane_id}') echo "%5" ;;
  '#{pane_pid}')
    if [ -f "$FAKE_STEPDIR/$count.pid" ]; then cat "$FAKE_STEPDIR/$count.pid"; else echo 100; fi ;;
  '#{pane_current_command}')
    if [ -f "$FAKE_STEPDIR/$count.cmd" ]; then cat "$FAKE_STEPDIR/$count.cmd"; else echo node; fi ;;
  esac
  ;;
capture-pane)
  if [ -f "$FAKE_STEPDIR/$count.txt" ]; then cat "$FAKE_STEPDIR/$count.txt"; fi
  echo $((count + 1)) >"$FAKE_COUNT"
  ;;
send-keys)
  prev=""
  for a in "$@"; do
    if [ "$prev" = "-l" ]; then printf '%s\n' "$a" >>"$FAKE_SENT"; fi
    prev="$a"
  done
  ;;
esac
EOF
  chmod +x "$FAKE"

  export RLR_TMUX="$FAKE"
  export FAKE_STEPDIR="$STEPDIR" FAKE_SENT="$SENT" FAKE_COUNT="$COUNT"
  export RLR_POLL_INTERVAL=0
}

# step <n> <cmd> <pid> <text>
step() {
  printf '%s' "$2" >"$STEPDIR/$1.cmd"
  printf '%s' "$3" >"$STEPDIR/$1.pid"
  printf '%s' "$4" >"$STEPDIR/$1.txt"
}

sent_count() {
  local n
  n="$(grep -c . "$SENT" 2>/dev/null || true)"
  echo "${n:-0}"
}

@test "recovered: sends once and exits 0 with resumed" {
  step 0 node 100 "usage limit reached"
  step 1 node 100 "usage limit reached"
  step 2 node 100 "assistant is thinking"
  step 3 node 100 "assistant is thinking"
  RLR_MAX_ITER=10 run bash "$SCRIPT" "sess:win.0" "再開して"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RLR: resumed"* ]]
  [ "$(sent_count)" -eq 1 ]
}

@test "permission prompt: never sends, emits human-needed, exit 3 on timeout" {
  step 0 node 100 "Do you want to proceed?"
  step 1 node 100 "Do you want to proceed?"
  RLR_MAX_ITER=2 run bash "$SCRIPT" "sess:win.0"
  [ "$status" -eq 3 ]
  [[ "$output" == *"RLR: permission-prompt human-needed"* ]]
  [ "$(sent_count)" -eq 0 ]
}

@test "claude gone (shell foreground): route-b exit 2, no send" {
  step 0 zsh 100 ""
  RLR_MAX_ITER=5 run bash "$SCRIPT" "sess:win.0"
  [ "$status" -eq 2 ]
  [[ "$output" == *"RLR: route-b claude-exited"* ]]
  [ "$(sent_count)" -eq 0 ]
}

@test "pane replaced (pane_pid changed): route-b exit 2" {
  step 0 node 100 "usage limit reached"
  step 1 node 999 "usage limit reached"
  RLR_MAX_ITER=5 run bash "$SCRIPT" "sess:win.0"
  [ "$status" -eq 2 ]
  [[ "$output" == *"RLR: route-b pane-replaced"* ]]
}

@test "ack fail (banner persists after send): bounded resend then exit 4" {
  step 0 node 100 "usage limit reached"
  step 1 node 100 "assistant is thinking"
  step 2 node 100 "usage limit reached"
  step 3 node 100 "usage limit reached"
  RLR_MAX_ITER=10 RLR_MAX_RESEND=1 run bash "$SCRIPT" "sess:win.0"
  [ "$status" -eq 4 ]
  [[ "$output" == *"RLR: resend-exhausted"* ]]
  # 初回送信 + 再送 1 = 計 2 回。
  [ "$(sent_count)" -eq 2 ]
}

@test "RLR_SIGNAL_FILE receives status lines" {
  step 0 node 100 "usage limit reached"
  step 1 node 100 "ready"
  step 2 node 100 "ready"
  sig="$BATS_TEST_TMPDIR/sig"
  RLR_MAX_ITER=10 RLR_SIGNAL_FILE="$sig" run bash "$SCRIPT" "sess:win.0"
  [ "$status" -eq 0 ]
  grep -q "RLR: resumed" "$sig"
}
