#!/usr/bin/env bats
# stuck-nudge.sh の E2E。
# PostToolUseFailure(Bash) で同種コマンドの連続失敗を数え、閾値 3 で codex-consult を促す
# additionalContext を注入する。PostToolUse(Bash) の成功で同種カウンタをリセット。
# 失敗判定は PostToolUseFailure(Bash) + 非 interrupt のみ(error 文言に依らない。F-001)。
# カウントはマーカーファイル数え上げ(F-002)。種別パーサは !/wrapper/クォート代入を剥がす(F-004)。
# 1 ctx 1 回(stuck-nudged-${ctx} claim ディレクトリ)/ subagent 抑制(agent_id)/ fail-open は
# capture-decision.bats・evolve-nudge.bats と同作法。実 wire 形式(spike-hooks.md)の JSON を fixture に。
# @test タイトルは ASCII 限定(日本語は bats のテスト名解決が壊れる既知の罠)。

load ../helpers/common

setup() {
  install_hooks
  unset XDG_STATE_HOME
  FLAG="$HOME/.claude/hooks/lib/flag-paths.sh"
}

# PostToolUseFailure / Bash。第1=ctx断片, 第2=command, 第3=error文言(省略時は汎用)。
_fail() {
  local err="${3:-Exit code 1}"
  printf '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","transcript_path":"/tmp/tp/%s.jsonl","error":"%s","is_interrupt":false,"tool_input":{"command":"%s"}}' "$1" "$err" "$2"
}

# PostToolUse / Bash(成功)。
_ok() {
  printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","transcript_path":"/tmp/tp/%s.jsonl","tool_response":{"stdout":"","stderr":""},"tool_input":{"command":"%s"}}' "$1" "$2"
}

# 種別カウント dir のマーカー数を返す(ctx kind)。
count_markers() {
  local h dir
  h="$("$FLAG" hash16 "$2")"
  dir="$("$FLAG" stuck-count-dir "$1" "$h")"
  find "$dir" -type f 2>/dev/null | wc -l | tr -d ' '
}

assert_nudged() {
  jq -e '.hookSpecificOutput.hookEventName == "PostToolUseFailure"
    and (.hookSpecificOutput.additionalContext | type == "string" and length > 0)' \
    <<<"$output" >/dev/null
}

@test "third consecutive same-kind failure nudges (threshold 3)" {
  run_hook stuck-nudge.sh "$(_fail sess-a 'git status')"
  [ -z "$output" ]
  run_hook stuck-nudge.sh "$(_fail sess-a 'git status')"
  [ -z "$output" ]
  run_hook stuck-nudge.sh "$(_fail sess-a 'git status')"
  [ "$status" -eq 0 ]
  assert_nudged
  jq -e '.hookSpecificOutput.additionalContext | contains("codex-consult")' <<<"$output" >/dev/null
}

@test "failure counts regardless of error wording (F-001)" {
  # error が "Exit code" 形式でなくても(公式例の文言でも)数える。
  run_hook stuck-nudge.sh "$(_fail sess-w 'make build' 'Command exited with non-zero status code 1')"
  [ -z "$output" ]
  run_hook stuck-nudge.sh "$(_fail sess-w 'make build' 'Command failed: make build')"
  [ -z "$output" ]
  run_hook stuck-nudge.sh "$(_fail sess-w 'make build' 'some other error text')"
  assert_nudged
}

@test "kind parser normalizes wrappers/assignments/bang to the same kind (F-004)" {
  # sudo / 環境変数代入(クォート付き)/ 否定 ! はすべて剥がされ、同じ種別 git に集約される。
  run_hook stuck-nudge.sh "$(_fail sess-k 'git fetch')"
  [ -z "$output" ]
  run_hook stuck-nudge.sh "$(_fail sess-k 'sudo git fetch')"
  [ -z "$output" ]
  run_hook stuck-nudge.sh "$(_fail sess-k 'GIT_TRACE=\"1 2\" git fetch')"
  assert_nudged
}

@test "same-kind success resets the counter" {
  run_hook stuck-nudge.sh "$(_fail sess-b 'git status')"
  run_hook stuck-nudge.sh "$(_fail sess-b 'git status')"
  # 成功でリセット
  run_hook stuck-nudge.sh "$(_ok sess-b 'git status')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(count_markers sess-b git)" -eq 0 ]
  # リセット後は 2 回失敗しても発火しない(閾値未満)
  run_hook stuck-nudge.sh "$(_fail sess-b 'git status')"
  [ -z "$output" ]
  run_hook stuck-nudge.sh "$(_fail sess-b 'git status')"
  [ -z "$output" ]
}

@test "excluded commands (non-zero is normal) are not counted" {
  local c
  for c in grep rg diff cmp; do
    run_hook stuck-nudge.sh "$(_fail sess-x "$c -q needle file")"
    [ -z "$output" ]
  done
  local i
  for i in 1 2 3 4 5; do
    run_hook stuck-nudge.sh "$(_fail sess-g 'grep -q x f')"
    [ -z "$output" ]
  done
}

@test "different-kind failures keep independent counters" {
  run_hook stuck-nudge.sh "$(_fail sess-c 'git status')"
  run_hook stuck-nudge.sh "$(_fail sess-c 'npm run build')"
  run_hook stuck-nudge.sh "$(_fail sess-c 'git status')"
  # git=2, npm=1 のどちらも閾値未満 → 発火しない
  [ -z "$output" ]
}

@test "nudge fires at most once per ctx" {
  run_hook stuck-nudge.sh "$(_fail sess-d 'git status')"
  run_hook stuck-nudge.sh "$(_fail sess-d 'git status')"
  run_hook stuck-nudge.sh "$(_fail sess-d 'git status')"
  assert_nudged
  run_hook stuck-nudge.sh "$(_fail sess-d 'git status')"
  [ -z "$output" ]
  run_hook stuck-nudge.sh "$(_fail sess-d 'git status')"
  [ -z "$output" ]
}

@test "parallel failures from zero: count reaches 5 and nudge fires exactly once" {
  # シード 0 から 5 並列で失敗させる。マーカー数え上げなのでロストせずカウント 5、
  # 閾値 3 到達で mkdir claim を取れた 1 プロセスだけがナッジ(F-002)。
  local outdir="$BATS_TEST_TMPDIR/par"
  mkdir -p "$outdir"
  local hook="$HOME/.claude/hooks/stuck-nudge.sh"
  local json i
  json="$(_fail sess-p 'git status')"
  for i in 1 2 3 4 5; do
    ( printf '%s' "$json" | "$hook" >"$outdir/$i" 2>&1 ) &
  done
  wait
  [ "$(count_markers sess-p git)" -eq 5 ]
  local hits
  hits="$(grep -l additionalContext "$outdir"/* 2>/dev/null | wc -l | tr -d ' ')"
  [ "$hits" -eq 1 ]
}

@test "subagent failure is suppressed (agent_id present)" {
  # メイン発で 2 回失敗(count=2)。次を subagent 発にすると数えず発火もしない。
  run_hook stuck-nudge.sh "$(_fail sess-s 'git status')"
  run_hook stuck-nudge.sh "$(_fail sess-s 'git status')"
  local json
  json="$(printf '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","agent_id":"a123","agent_type":"general-purpose","transcript_path":"/tmp/tp/sess-s.jsonl","error":"Exit code 1","is_interrupt":false,"tool_input":{"command":"git status"}}')"
  run_hook stuck-nudge.sh "$json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(count_markers sess-s git)" -eq 2 ]
}

@test "interrupt is not counted" {
  run_hook stuck-nudge.sh "$(_fail sess-i 'git status')"
  run_hook stuck-nudge.sh "$(_fail sess-i 'git status')"
  local json
  json="$(printf '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","transcript_path":"/tmp/tp/sess-i.jsonl","error":"Exit code 1","is_interrupt":true,"tool_input":{"command":"git status"}}')"
  run_hook stuck-nudge.sh "$json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(count_markers sess-i git)" -eq 2 ]
}

@test "session_id fallback: same session_id accumulates" {
  local j
  j='{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","session_id":"sess-sid","error":"Exit code 1","is_interrupt":false,"tool_input":{"command":"git status"}}'
  run_hook stuck-nudge.sh "$j"
  run_hook stuck-nudge.sh "$j"
  run_hook stuck-nudge.sh "$j"
  [ "$status" -eq 0 ]
  assert_nudged
}

@test "fail-open when jq is absent (no output, exit 0)" {
  run_hook_env "$(make_no_jq_path)" stuck-nudge.sh "$(_fail sess-nojq 'git status')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fail-open when state dir is unwritable" {
  touch "$BATS_TEST_TMPDIR/notadir"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/notadir"
  run_hook stuck-nudge.sh "$(_fail sess-ro 'git status')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run_hook stuck-nudge.sh "$(_fail sess-ro 'git status')"
  run_hook stuck-nudge.sh "$(_fail sess-ro 'git status')"
  [ -z "$output" ]
}

@test "rearm re-arms the nudge (re-fire after clear/compact)" {
  run_hook stuck-nudge.sh "$(_fail sess-r 'git status')"
  run_hook stuck-nudge.sh "$(_fail sess-r 'git status')"
  run_hook stuck-nudge.sh "$(_fail sess-r 'git status')"
  assert_nudged
  run_hook stuck-nudge.sh "$(_fail sess-r 'git status')"
  [ -z "$output" ]
  run_hook rearm-coding-standards.sh '{"transcript_path":"/tmp/tp/sess-r.jsonl"}'
  [ "$status" -eq 0 ]
  [ "$(count_markers sess-r git)" -eq 0 ]
  run_hook stuck-nudge.sh "$(_fail sess-r 'git status')"
  [ -z "$output" ]
  run_hook stuck-nudge.sh "$(_fail sess-r 'git status')"
  [ -z "$output" ]
  run_hook stuck-nudge.sh "$(_fail sess-r 'git status')"
  assert_nudged
}
