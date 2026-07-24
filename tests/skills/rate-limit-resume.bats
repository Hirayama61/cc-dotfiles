#!/usr/bin/env bats
# tmux-claude-drive 付属の rate-limit-resume.sh の状態機械を固定する。
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
  SCRIPT="$REPO_ROOT/home/dot_claude/skills/tmux-claude-drive/scripts/executable_rate-limit-resume.sh"

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
  export RLR_POLL_INTERVAL=0 RLR_SEND_DELAY=0
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

@test "permission detect error: grep failure is treated as prompt (never sends)" {
  # PERMISSION_ERE の照合だけを rc=2(照合エラー)に化けさせる grep shim。banner 判定など
  # 他の grep は実物へ委譲する(全部落とすと usage limit 検知まで壊れて別経路になる)。
  shim="$BATS_TEST_TMPDIR/bin"
  marker="$BATS_TEST_TMPDIR/shim-fired"
  mkdir -p "$shim"
  cat >"$shim/grep" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
  *"do you trust"*) : >"$marker"; exit 2 ;;
  esac
done
exec /usr/bin/grep "\$@"
EOF
  chmod +x "$shim/grep"

  # 画面は PERMISSION_ERE に一致しない文言にする。shim が発火しなくなった時に実 grep が
  # rc=1(不一致)を返して送信に回り、テストが空洞化せず落ちるようにするため
  # (プロンプト文言のままだと実 grep も rc=0 になり、shim 不発でも同じ観測結果になる)。
  step 0 node 100 "usage limit reached"
  step 1 node 100 "usage limit reached"
  step 2 node 100 "assistant is thinking"
  step 3 node 100 "assistant is thinking"
  PATH="$shim:$PATH" RLR_MAX_ITER=4 run bash "$SCRIPT" "sess:win.0"
  # shim が実際に照合エラー経路を通したことを固定する(通っていなければ以下は無意味)。
  [ -f "$marker" ]
  # 照合不能を「プロンプト無し」に倒すと再開フレーズを送ってしまう(permission laundering)。
  [ "$(sent_count)" -eq 0 ]
  [[ "$output" == *"permission-prompt human-needed"* ]]
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

@test "mid-poll pane lost (empty pane_pid during loop): route-b exit 2" {
  step 0 node 100 "usage limit reached"
  step 1 node "" "usage limit reached"
  RLR_MAX_ITER=5 run bash "$SCRIPT" "sess:win.0"
  [ "$status" -eq 2 ]
  [[ "$output" == *"RLR: route-b pane-lost"* ]]
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

@test "startup: unresolvable pane (empty pane_pid) fails fast to route-b exit 2" {
  step 0 node "" ""
  RLR_MAX_ITER=5 run bash "$SCRIPT" "sess:win.0"
  [ "$status" -eq 2 ]
  [[ "$output" == *"RLR: route-b pane-unresolved"* ]]
  [ "$(sent_count)" -eq 0 ]
}

@test "RLR_RESET_PARSE is invoked while limited" {
  step 0 node 100 "usage limit reached"
  step 1 node 100 "assistant is thinking"
  step 2 node 100 "assistant is thinking"
  marker="$BATS_TEST_TMPDIR/parsed"
  parser="$BATS_TEST_TMPDIR/parser"
  cat >"$parser" <<EOF
#!/usr/bin/env bash
cat >/dev/null
printf done >>"$marker"
echo 0
EOF
  chmod +x "$parser"
  RLR_MAX_ITER=10 RLR_RESET_PARSE="$parser" run bash "$SCRIPT" "sess:win.0"
  [ "$status" -eq 0 ]
  [ -f "$marker" ]
}

@test "permission stuck: gives up with exit 5 after RLR_PERMSTUCK_MAX_ITERS" {
  step 0 node 100 "Do you want to proceed?"
  step 1 node 100 "Do you want to proceed?"
  step 2 node 100 "Do you want to proceed?"
  RLR_MAX_ITER=20 RLR_PERMSTUCK_MAX_ITERS=2 run bash "$SCRIPT" "sess:win.0"
  [ "$status" -eq 5 ]
  [[ "$output" == *"RLR: permission-stuck"* ]]
  [ "$(sent_count)" -eq 0 ]
}

# 内蔵リセット時刻パーサ(--parse-reset 自己テストフック。ループを回さず stdin を評価)。
parse_reset() { printf '%s' "$1" | bash "$SCRIPT" --parse-reset; }

@test "reset parser: 'in 2 hours' -> 7200" {
  [ "$(parse_reset 'usage limit. try again in 2 hours')" -eq 7200 ]
}

@test "reset parser: 'in 15 minutes' -> 900" {
  [ "$(parse_reset 'rate limit reached, resets in 15 minutes')" -eq 900 ]
}

@test "reset parser: no time -> 0 (interval fallback)" {
  [ "$(parse_reset 'usage limit reached')" -eq 0 ]
}

@test "reset parser: relative time only in limit context ('try again in 2 hours' -> 7200)" {
  [ "$(parse_reset 'usage limit. try again in 2 hours')" -eq 7200 ]
}

@test "reset parser: unrelated 'completed in 2 hours' is ignored -> 0" {
  [ "$(parse_reset 'the build completed in 2 hours, nice')" -eq 0 ]
}

@test "reset parser: invalid clock 'at 25:99pm' -> 0" {
  [ "$(parse_reset 'reset available again at 25:99pm')" -eq 0 ]
}

@test "reset parser: out-of-range value in limit context -> 0 (range guard)" {
  # limit 文脈を満たした上で 999h(>6h)が範囲ガードで 0 になることを検証。
  [ "$(parse_reset 'usage limit, try again in 999 hours')" -eq 0 ]
}

@test "reset parser: 'at 5pm' without minutes does not crash (numeric out)" {
  n="$(parse_reset 'reset available again at 5pm')"
  [[ "$n" =~ ^[0-9]+$ ]]
}

@test "reset parser: absolute 'at H:MM(am|pm)' yields 0 or a bounded second count" {
  n="$(parse_reset 'available again at 11:30pm')"
  [[ "$n" =~ ^[0-9]+$ ]]
  # 内蔵ガードにより 0(=interval)か 60..21600 のいずれか(clock 依存)。
  [ "$n" -eq 0 ] || { [ "$n" -ge 60 ] && [ "$n" -le 21600 ]; }
}

@test "permission detect: ASCII cursor '> 1. Yes' is treated as prompt (never sends)" {
  step 0 node 100 "> 1. Yes"
  step 1 node 100 "> 1. Yes"
  RLR_MAX_ITER=2 run bash "$SCRIPT" "sess:win.0"
  [ "$status" -eq 3 ]
  [[ "$output" == *"permission-prompt human-needed"* ]]
  [ "$(sent_count)" -eq 0 ]
}

@test "permission detect: normal output '> 123 files changed' is NOT a prompt (sends on clear)" {
  step 0 node 100 "usage limit reached"
  step 1 node 100 "> 123 files changed and other normal output"
  step 2 node 100 "> 123 files changed and other normal output"
  RLR_MAX_ITER=10 run bash "$SCRIPT" "sess:win.0"
  # limit→通常出力(誤検知しない)なら明けたとみなして送信し resumed。
  [ "$status" -eq 0 ]
  [ "$(sent_count)" -eq 1 ]
}

@test "reset parser: leading-zero minutes 'in 08 minutes' -> 480 (10# base-10, no octal crash)" {
  [ "$(parse_reset 'try again in 08 minutes')" -eq 480 ]
}

@test "reset parser: leading-zero hours 'in 05 hours' -> 18000" {
  [ "$(parse_reset 'usage limit. in 05 hours')" -eq 18000 ]
}

@test "reset parser: leading-zero clock 'at 08:09am' does not crash (numeric out)" {
  n="$(parse_reset 'available again at 08:09am')"
  [[ "$n" =~ ^[0-9]+$ ]]
}

@test "reset deadline is computed once, not re-parsed every poll" {
  # 全ポーリングで limited を返す。相対時刻を毎回再解釈するバグなら parser が複数回呼ばれる。
  step 0 node 100 "usage limit, try again soon"
  step 1 node 100 "usage limit, try again soon"
  step 2 node 100 "usage limit, try again soon"
  step 3 node 100 "usage limit, try again soon"
  cnt="$BATS_TEST_TMPDIR/pcnt"
  echo 0 >"$cnt"
  parser="$BATS_TEST_TMPDIR/pincr"
  cat >"$parser" <<EOF
#!/usr/bin/env bash
cat >/dev/null
n=\$(cat "$cnt"); echo \$((n + 1)) >"$cnt"
echo 1
EOF
  chmod +x "$parser"
  RLR_MAX_ITER=4 RLR_RESET_PARSE="$parser" run bash "$SCRIPT" "sess:win.0"
  [ "$status" -eq 3 ]
  [ "$(cat "$cnt")" -eq 1 ]
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

@test "--print-permission-ere: emits non-empty single-line ERE matching known prompts" {
  run bash "$SCRIPT" --print-permission-ere
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "${#lines[@]}" -eq 1 ]
  printf '%s' '❯ 1. Yes' | grep -qiE "$output"
  printf '%s' 'Do you want to proceed' | grep -qiE "$output"
  ! printf '%s' '> 123 files changed' | grep -qiE "$output"
}
