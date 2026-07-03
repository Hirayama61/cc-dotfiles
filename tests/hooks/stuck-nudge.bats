#!/usr/bin/env bats
# stuck-nudge.sh の E2E。
# PostToolUseFailure(Bash) で同種コマンドの連続失敗を数え、閾値 3 で codex-consult を促す
# additionalContext を注入する。PostToolUse(Bash) の成功で同種カウンタをリセット。
# 1 ctx 1 回(stuck-nudged-${ctx} claim ディレクトリ)/ subagent 抑制(agent_id)/
# 並列でナッジ高々1回 / fail-open は capture-decision.bats・evolve-nudge.bats と同作法。
# 実 wire 形式(spike-hooks.md 採取)の入力 JSON を fixture にする。
# @test タイトルは ASCII 限定(日本語は bats のテスト名解決が壊れる既知の罠)。

load ../helpers/common

setup() {
  install_hooks
  unset XDG_STATE_HOME
  FLAG="$HOME/.claude/hooks/lib/flag-paths.sh"
}

# PostToolUseFailure / Bash(実 exit code 失敗)。第1=ctx断片, 第2=command。
_fail() {
  printf '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","transcript_path":"/tmp/tp/%s.jsonl","error":"Exit code 1","is_interrupt":false,"tool_input":{"command":"%s"}}' "$1" "$2"
}

# PostToolUse / Bash(成功)。
_ok() {
  printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","transcript_path":"/tmp/tp/%s.jsonl","tool_response":{"stdout":"","stderr":""},"tool_input":{"command":"%s"}}' "$1" "$2"
}

# 種別カウンタを直接シードする(ctx kind value)。
seed_stuck() {
  "$FLAG" dir-ensure >/dev/null
  local h cf
  h="$("$FLAG" hash16 "$2")"
  cf="$("$FLAG" stuck-count "$1" "$h")"
  printf '%s' "$3" >"$cf"
}

assert_nudged() {
  jq -e '.hookSpecificOutput.hookEventName == "PostToolUseFailure"
    and (.hookSpecificOutput.additionalContext | type == "string" and length > 0)' \
    <<<"$output" >/dev/null
}

@test "third consecutive same-kind failure nudges (threshold 3)" {
  run_hook stuck-nudge.sh "$(_fail sess-a 'git push')"
  [ -z "$output" ]
  run_hook stuck-nudge.sh "$(_fail sess-a 'git push')"
  [ -z "$output" ]
  run_hook stuck-nudge.sh "$(_fail sess-a 'git push')"
  [ "$status" -eq 0 ]
  assert_nudged
  jq -e '.hookSpecificOutput.additionalContext | contains("codex-consult")' <<<"$output" >/dev/null
}

@test "same-kind success resets the counter" {
  run_hook stuck-nudge.sh "$(_fail sess-b 'git push')"
  run_hook stuck-nudge.sh "$(_fail sess-b 'git push')"
  # 成功でリセット
  run_hook stuck-nudge.sh "$(_ok sess-b 'git status')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # リセット後は 2 回失敗しても発火しない(閾値未満)
  run_hook stuck-nudge.sh "$(_fail sess-b 'git push')"
  [ -z "$output" ]
  run_hook stuck-nudge.sh "$(_fail sess-b 'git push')"
  [ -z "$output" ]
}

@test "excluded commands (non-zero is normal) are not counted" {
  local c
  for c in grep rg diff cmp; do
    run_hook stuck-nudge.sh "$(_fail sess-x "$c -q needle file")"
    [ -z "$output" ]
  done
  # grep を 5 回失敗させても発火しない
  local i
  for i in 1 2 3 4 5; do
    run_hook stuck-nudge.sh "$(_fail sess-g 'grep -q x f')"
    [ -z "$output" ]
  done
}

@test "different-kind failures keep independent counters" {
  run_hook stuck-nudge.sh "$(_fail sess-c 'git push')"
  run_hook stuck-nudge.sh "$(_fail sess-c 'npm run build')"
  run_hook stuck-nudge.sh "$(_fail sess-c 'git push')"
  # git=2, npm=1 のどちらも閾値未満 → 発火しない
  [ -z "$output" ]
}

@test "nudge fires at most once per ctx" {
  run_hook stuck-nudge.sh "$(_fail sess-d 'git push')"
  run_hook stuck-nudge.sh "$(_fail sess-d 'git push')"
  run_hook stuck-nudge.sh "$(_fail sess-d 'git push')"
  assert_nudged
  # 4 回目・5 回目は claim 済みで無音
  run_hook stuck-nudge.sh "$(_fail sess-d 'git push')"
  [ -z "$output" ]
  run_hook stuck-nudge.sh "$(_fail sess-d 'git push')"
  [ -z "$output" ]
}

@test "parallel failures nudge exactly once (mkdir atomic claim)" {
  # 閾値直前までシードし、5 並列で失敗させる。mkdir claim を取れた 1 プロセスだけが発火。
  seed_stuck sess-p 'git' 2
  local outdir="$BATS_TEST_TMPDIR/par"
  mkdir -p "$outdir"
  local hook="$HOME/.claude/hooks/stuck-nudge.sh"
  local json i
  json="$(_fail sess-p 'git push')"
  for i in 1 2 3 4 5; do
    ( printf '%s' "$json" | "$hook" >"$outdir/$i" 2>&1 ) &
  done
  wait
  local hits
  hits="$(grep -l additionalContext "$outdir"/* 2>/dev/null | wc -l | tr -d ' ')"
  [ "$hits" -eq 1 ]
}

@test "subagent failure is suppressed (agent_id present)" {
  seed_stuck sess-s 'git' 2
  local json
  json="$(printf '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","agent_id":"a123","agent_type":"general-purpose","transcript_path":"/tmp/tp/sess-s.jsonl","error":"Exit code 1","is_interrupt":false,"tool_input":{"command":"git push"}}')"
  run_hook stuck-nudge.sh "$json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "interrupt is not counted" {
  seed_stuck sess-i 'git' 2
  local json
  json="$(printf '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","transcript_path":"/tmp/tp/sess-i.jsonl","error":"Exit code 1","is_interrupt":true,"tool_input":{"command":"git push"}}')"
  run_hook stuck-nudge.sh "$json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "non-exit-code error (permission etc.) is not counted" {
  seed_stuck sess-perm 'git' 2
  local json
  json="$(printf '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","transcript_path":"/tmp/tp/sess-perm.jsonl","error":"Permission denied","is_interrupt":false,"tool_input":{"command":"git push"}}')"
  run_hook stuck-nudge.sh "$json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "session_id fallback: same session_id accumulates" {
  local j
  j='{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","session_id":"sess-sid","error":"Exit code 1","is_interrupt":false,"tool_input":{"command":"git push"}}'
  run_hook stuck-nudge.sh "$j"
  run_hook stuck-nudge.sh "$j"
  run_hook stuck-nudge.sh "$j"
  [ "$status" -eq 0 ]
  assert_nudged
}

@test "fail-open when jq is absent (no output, exit 0)" {
  seed_stuck sess-nojq 'git' 2
  run_hook_env "$(make_no_jq_path)" stuck-nudge.sh "$(_fail sess-nojq 'git push')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fail-open when state dir is unwritable" {
  # XDG_STATE_HOME をファイルにして mkdir を失敗させる(claude_flag_dir_ensure が return 1)。
  touch "$BATS_TEST_TMPDIR/notadir"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/notadir"
  run_hook stuck-nudge.sh "$(_fail sess-ro 'git push')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run_hook stuck-nudge.sh "$(_fail sess-ro 'git push')"
  run_hook stuck-nudge.sh "$(_fail sess-ro 'git push')"
  [ -z "$output" ]
}

@test "rearm re-arms the nudge (re-fire after clear/compact)" {
  run_hook stuck-nudge.sh "$(_fail sess-r 'git push')"
  run_hook stuck-nudge.sh "$(_fail sess-r 'git push')"
  run_hook stuck-nudge.sh "$(_fail sess-r 'git push')"
  assert_nudged
  run_hook stuck-nudge.sh "$(_fail sess-r 'git push')"
  [ -z "$output" ]
  run_hook rearm-coding-standards.sh '{"transcript_path":"/tmp/tp/sess-r.jsonl"}'
  [ "$status" -eq 0 ]
  # rearm 後はカウンタも claim も消え、再び 3 回で発火する。
  run_hook stuck-nudge.sh "$(_fail sess-r 'git push')"
  [ -z "$output" ]
  run_hook stuck-nudge.sh "$(_fail sess-r 'git push')"
  [ -z "$output" ]
  run_hook stuck-nudge.sh "$(_fail sess-r 'git push')"
  assert_nudged
}
