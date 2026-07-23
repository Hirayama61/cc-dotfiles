#!/usr/bin/env bats
# capture-transcript.sh の characterization。
# 発話の逐語 JSONL 追記・ターンカウンタ・override フレーズ検知。

load ../helpers/common

CTX="test-ctx-c"

setup() {
  install_hooks
  CACHE="$HOME/.cache/claude-context/$CTX"
  TP="/Users/x/.claude/projects/-p/$CTX.jsonl"
}

prompt_json() {
  printf '{"hook_event_name":"UserPromptSubmit","transcript_path":"%s","prompt":"%s"}' "$TP" "$1"
}

@test "appends prompt verbatim and increments turn" {
  run_hook capture-transcript.sh "$(prompt_json "first message")"
  [ "$status" -ne 2 ]
  run_hook capture-transcript.sh "$(prompt_json "second message")"
  [ "$(cat "$CACHE/turn")" = "2" ]
  [ "$(wc -l < "$CACHE/decisions.jsonl" | tr -d ' ')" = "2" ]
  head -1 "$CACHE/decisions.jsonl" | jq -e '.type == "prompt" and .content == "first message" and .turn == 1' >/dev/null
  tail -1 "$CACHE/decisions.jsonl" | jq -e '.turn == 2' >/dev/null
}

@test "override phrase writes override marker" {
  run_hook capture-transcript.sh "$(prompt_json "emergency: context-gate-override please")"
  [ -f "$CACHE/override" ]
}

@test "normal prompt does not write override marker" {
  run_hook capture-transcript.sh "$(prompt_json "just talking about overrides in general")"
  [ ! -f "$CACHE/override" ]
}

@test "empty prompt: no append" {
  run_hook capture-transcript.sh "{\"hook_event_name\":\"UserPromptSubmit\",\"transcript_path\":\"$TP\",\"prompt\":\"\"}"
  [ ! -f "$CACHE/decisions.jsonl" ]
}

@test "no transcript_path: silent noop" {
  run_hook capture-transcript.sh '{"hook_event_name":"UserPromptSubmit","prompt":"x"}'
  [ "$status" -ne 2 ]
}

@test "no jq: fail-open" {
  run_hook_env "$(make_no_jq_path)" capture-transcript.sh "$(prompt_json "x")"
  [ "$status" -ne 2 ]
}
