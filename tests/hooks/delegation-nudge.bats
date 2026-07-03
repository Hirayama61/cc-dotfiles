#!/usr/bin/env bats
# delegation-nudge.sh の E2E。
# PostToolUse(Grep|Glob) の ctx 累計が閾値 5 に達したら委譲(scout/researcher/delegate の
# 出し分け)を促す additionalContext を注入する。PostToolUse(Agent) で累計をリセット。
# Read は数えない / 1 ctx 1 回 / subagent 抑制(agent_id)/ 並列で高々1回 / fail-open。
# @test タイトルは ASCII 限定(日本語は bats のテスト名解決が壊れる既知の罠)。

load ../helpers/common

setup() {
  install_hooks
  unset XDG_STATE_HOME
  FLAG="$HOME/.claude/hooks/lib/flag-paths.sh"
}

# PostToolUse / 任意ツール。第1=ctx断片, 第2=tool_name。
_tool() {
  printf '{"hook_event_name":"PostToolUse","tool_name":"%s","transcript_path":"/tmp/tp/%s.jsonl","tool_input":{"pattern":"x"}}' "$2" "$1"
}

seed_delegation() {
  "$FLAG" dir-ensure >/dev/null
  local cf
  cf="$("$FLAG" delegation-count "$1")"
  printf '%s' "$2" >"$cf"
}

assert_nudged() {
  jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"
    and (.hookSpecificOutput.additionalContext | type == "string" and length > 0)' \
    <<<"$output" >/dev/null
}

@test "fifth search (Grep/Glob) nudges (threshold 5)" {
  local i
  for i in 1 2 3 4; do
    run_hook delegation-nudge.sh "$(_tool sess-a Grep)"
    [ -z "$output" ]
  done
  run_hook delegation-nudge.sh "$(_tool sess-a Glob)"
  [ "$status" -eq 0 ]
  assert_nudged
  jq -e '.hookSpecificOutput.additionalContext | contains("scout")
    and contains("researcher") and contains("delegate")' <<<"$output" >/dev/null
}

@test "Read is not counted" {
  local i
  for i in 1 2 3 4 5 6 7; do
    run_hook delegation-nudge.sh "$(_tool sess-r Read)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "Agent use resets the counter" {
  local i
  for i in 1 2 3 4; do
    run_hook delegation-nudge.sh "$(_tool sess-b Grep)"
  done
  run_hook delegation-nudge.sh "$(_tool sess-b Agent)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # リセット後は 4 回探索しても発火しない
  for i in 1 2 3 4; do
    run_hook delegation-nudge.sh "$(_tool sess-b Grep)"
    [ -z "$output" ]
  done
}

@test "nudge fires at most once per ctx" {
  local i
  for i in 1 2 3 4 5; do
    run_hook delegation-nudge.sh "$(_tool sess-c Grep)"
  done
  assert_nudged
  run_hook delegation-nudge.sh "$(_tool sess-c Grep)"
  [ -z "$output" ]
  run_hook delegation-nudge.sh "$(_tool sess-c Glob)"
  [ -z "$output" ]
}

@test "parallel searches nudge exactly once (mkdir atomic claim)" {
  seed_delegation sess-p 4
  local outdir="$BATS_TEST_TMPDIR/par"
  mkdir -p "$outdir"
  local hook="$HOME/.claude/hooks/delegation-nudge.sh"
  local json i
  json="$(_tool sess-p Grep)"
  for i in 1 2 3 4 5; do
    ( printf '%s' "$json" | "$hook" >"$outdir/$i" 2>&1 ) &
  done
  wait
  local hits
  hits="$(grep -l additionalContext "$outdir"/* 2>/dev/null | wc -l | tr -d ' ')"
  [ "$hits" -eq 1 ]
}

@test "subagent search is suppressed (agent_id present)" {
  seed_delegation sess-s 4
  local json
  json="$(printf '{"hook_event_name":"PostToolUse","tool_name":"Grep","agent_id":"a123","agent_type":"general-purpose","transcript_path":"/tmp/tp/sess-s.jsonl","tool_input":{"pattern":"x"}}')"
  run_hook delegation-nudge.sh "$json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "session_id fallback: same session_id accumulates" {
  local j
  j='{"hook_event_name":"PostToolUse","tool_name":"Grep","session_id":"sess-sid","tool_input":{"pattern":"x"}}'
  local i
  for i in 1 2 3 4 5; do
    run_hook delegation-nudge.sh "$j"
  done
  [ "$status" -eq 0 ]
  assert_nudged
}

@test "fail-open when jq is absent (no output, exit 0)" {
  seed_delegation sess-nojq 4
  run_hook_env "$(make_no_jq_path)" delegation-nudge.sh "$(_tool sess-nojq Grep)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fail-open when state dir is unwritable" {
  touch "$BATS_TEST_TMPDIR/notadir"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/notadir"
  local i
  for i in 1 2 3 4 5 6; do
    run_hook delegation-nudge.sh "$(_tool sess-ro Grep)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "rearm re-arms the nudge (re-fire after clear/compact)" {
  local i
  for i in 1 2 3 4 5; do
    run_hook delegation-nudge.sh "$(_tool sess-r Grep)"
  done
  assert_nudged
  run_hook delegation-nudge.sh "$(_tool sess-r Grep)"
  [ -z "$output" ]
  run_hook rearm-coding-standards.sh '{"transcript_path":"/tmp/tp/sess-r.jsonl"}'
  [ "$status" -eq 0 ]
  for i in 1 2 3 4; do
    run_hook delegation-nudge.sh "$(_tool sess-r Grep)"
    [ -z "$output" ]
  done
  run_hook delegation-nudge.sh "$(_tool sess-r Grep)"
  assert_nudged
}
