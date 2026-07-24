#!/usr/bin/env bats
# capture-plan-qa.sh の characterization。
# ExitPlanMode の plan 本文 / AskUserQuestion の Q&A の JSONL 追記と subagent 除外。

load ../helpers/common

CTX="test-ctx-q"

setup() {
  install_hooks
  CACHE="$HOME/.cache/claude-context/$CTX"
  TP="/Users/x/.claude/projects/-p/$CTX.jsonl"
}

@test "ExitPlanMode: appends plan entry" {
  json="$(printf '{"hook_event_name":"PostToolUse","tool_name":"ExitPlanMode","transcript_path":"%s","tool_input":{"plan":"step1 then step2"}}' "$TP")"
  run_hook capture-plan-qa.sh "$json"
  [ "$status" -ne 2 ]
  tail -1 "$CACHE/decisions.jsonl" | jq -e '.type == "plan" and .content == "step1 then step2"' >/dev/null
}

@test "AskUserQuestion: appends questions and answers" {
  json="$(printf '{"hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","transcript_path":"%s","tool_input":{"questions":[{"question":"which way?"}]},"tool_response":{"questions":[],"answers":{"which way?":"plan A"},"annotations":{}}}' "$TP")"
  run_hook capture-plan-qa.sh "$json"
  [ "$status" -ne 2 ]
  tail -1 "$CACHE/decisions.jsonl" | jq -e '.type == "qa" and .questions == ["which way?"] and .answers["which way?"] == "plan A"' >/dev/null
}

@test "AskUserQuestion without answers: degrades to questions only" {
  json="$(printf '{"hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","transcript_path":"%s","tool_input":{"questions":[{"question":"q1"}]}}' "$TP")"
  run_hook capture-plan-qa.sh "$json"
  tail -1 "$CACHE/decisions.jsonl" | jq -e '.type == "qa" and .questions == ["q1"] and .answers == null' >/dev/null
}

@test "subagent input (agent_id): not recorded" {
  json="$(printf '{"hook_event_name":"PostToolUse","tool_name":"ExitPlanMode","agent_id":"a1","transcript_path":"%s","tool_input":{"plan":"sub plan"}}' "$TP")"
  run_hook capture-plan-qa.sh "$json"
  [ "$status" -ne 2 ]
  [ ! -f "$CACHE/decisions.jsonl" ]
}

@test "other tools: not recorded" {
  json="$(printf '{"hook_event_name":"PostToolUse","tool_name":"Edit","transcript_path":"%s","tool_input":{"file_path":"/tmp/f"}}' "$TP")"
  run_hook capture-plan-qa.sh "$json"
  [ ! -f "$CACHE/decisions.jsonl" ]
}

@test "empty plan: no entry" {
  json="$(printf '{"hook_event_name":"PostToolUse","tool_name":"ExitPlanMode","transcript_path":"%s","tool_input":{}}' "$TP")"
  run_hook capture-plan-qa.sh "$json"
  if [ -f "$CACHE/decisions.jsonl" ]; then
    [ "$(wc -l < "$CACHE/decisions.jsonl" | tr -d ' ')" = "0" ]
  fi
}

@test "no jq: fail-open" {
  json="$(printf '{"hook_event_name":"PostToolUse","tool_name":"ExitPlanMode","transcript_path":"%s","tool_input":{"plan":"p"}}' "$TP")"
  run_hook_env "$(make_no_jq_path)" capture-plan-qa.sh "$json"
  [ "$status" -ne 2 ]
}
