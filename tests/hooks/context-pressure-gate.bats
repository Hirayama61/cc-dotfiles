#!/usr/bin/env bats
# context-pressure-gate.sh の characterization。
# 50% 最終通告ライン: subagent 素通し / usage 不在・stale 素通し / 50% 未満素通し /
# 検知ターンは警告つき allow / 猶予超過で exit 2 / override 1 回解除 / cache 配下 Write 素通し。

load ../helpers/common

CTX="test-ctx-1"

setup() {
  install_hooks
  CACHE="$HOME/.cache/claude-context/$CTX"
  mkdir -p "$CACHE"
  TP="/Users/x/.claude/projects/-p/$CTX.jsonl"
}

write_usage() {
  # $1 = pct, $2 = updated_at offset seconds ago (default 0)
  local ago="${2:-0}"
  printf '{"pct": %s, "transcript_path": "%s", "updated_at": %s}' \
    "$1" "$TP" "$(( $(date +%s) - ago ))" > "$CACHE/usage.json"
}

edit_json() {
  printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","transcript_path":"%s","tool_input":{"file_path":"%s"}}' "$TP" "${1:-/tmp/some/file.txt}"
}

@test "below 50: allowed" {
  write_usage 49.9
  echo 3 > "$CACHE/turn"
  run_hook context-pressure-gate.sh "$(edit_json)"
  [ "$status" -ne 2 ]
}

@test "no usage.json: allowed (fail-open)" {
  echo 3 > "$CACHE/turn"
  run_hook context-pressure-gate.sh "$(edit_json)"
  [ "$status" -ne 2 ]
}

@test "stale usage.json: allowed (fail-open)" {
  write_usage 80 2000
  echo 3 > "$CACHE/turn"
  echo 1 > "$CACHE/grace-turn"
  run_hook context-pressure-gate.sh "$(edit_json)"
  [ "$status" -ne 2 ]
}

@test "subagent input (agent_id present): allowed" {
  write_usage 80
  echo 3 > "$CACHE/turn"
  echo 1 > "$CACHE/grace-turn"
  json="$(printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","agent_id":"a1","transcript_path":"%s","tool_input":{"file_path":"/tmp/f"}}' "$TP")"
  run_hook context-pressure-gate.sh "$json"
  [ "$status" -ne 2 ]
}

@test "first detection turn: allowed with warning and grace recorded" {
  write_usage 55
  echo 7 > "$CACHE/turn"
  run_hook context-pressure-gate.sh "$(edit_json)"
  [ "$status" -ne 2 ]
  echo "$output" | grep -qF 'additionalContext'
  echo "$output" | grep -qF '最終通告'
  [ "$(cat "$CACHE/grace-turn")" = "7" ]
}

@test "same turn as grace: still allowed" {
  write_usage 55
  echo 7 > "$CACHE/turn"
  echo 7 > "$CACHE/grace-turn"
  run_hook context-pressure-gate.sh "$(edit_json)"
  [ "$status" -ne 2 ]
}

@test "turn after grace: blocked with compact-prep guidance" {
  write_usage 55
  echo 8 > "$CACHE/turn"
  echo 7 > "$CACHE/grace-turn"
  run_hook context-pressure-gate.sh "$(edit_json)"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'compact-prep'
}

@test "override marker: allowed once and consumed" {
  write_usage 55
  echo 8 > "$CACHE/turn"
  echo 7 > "$CACHE/grace-turn"
  touch "$CACHE/override"
  run_hook context-pressure-gate.sh "$(edit_json)"
  [ "$status" -ne 2 ]
  [ ! -f "$CACHE/override" ]
  # 消費後は再びブロック
  run_hook context-pressure-gate.sh "$(edit_json)"
  [ "$status" -eq 2 ]
}

@test "write into cache dir (state file): allowed even after grace" {
  write_usage 55
  echo 8 > "$CACHE/turn"
  echo 7 > "$CACHE/grace-turn"
  run_hook context-pressure-gate.sh "$(edit_json "$CACHE/state.md")"
  [ "$status" -ne 2 ]
}

@test "no jq: allowed (fail-open)" {
  write_usage 55
  echo 8 > "$CACHE/turn"
  echo 7 > "$CACHE/grace-turn"
  run_hook_env "$(make_no_jq_path)" context-pressure-gate.sh "$(edit_json)"
  [ "$status" -ne 2 ]
}

@test "no turn file: allowed (fail-open)" {
  write_usage 55
  rm -f "$CACHE/turn"
  run_hook context-pressure-gate.sh "$(edit_json)"
  [ "$status" -ne 2 ]
}
