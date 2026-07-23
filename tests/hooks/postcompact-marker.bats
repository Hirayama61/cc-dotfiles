#!/usr/bin/env bats
# postcompact-marker.sh の characterization。
# compacted marker の書込と通知系フラグ(notified-pct / grace-turn / precompact-blocked)の
# 再武装。state.md / decisions.jsonl は消さないこと。

load ../helpers/common

CTX="test-ctx-m"

setup() {
  install_hooks
  CACHE="$HOME/.cache/claude-context/$CTX"
  mkdir -p "$CACHE"
  TP="/Users/x/.claude/projects/-p/$CTX.jsonl"
}

@test "writes compacted marker and rearms flags, keeps state and log" {
  echo 45 > "$CACHE/notified-pct"
  echo 7 > "$CACHE/grace-turn"
  touch "$CACHE/precompact-blocked"
  echo state > "$CACHE/state.md"
  echo '{"type":"prompt"}' > "$CACHE/decisions.jsonl"
  run_hook postcompact-marker.sh "{\"hook_event_name\":\"PostCompact\",\"transcript_path\":\"$TP\"}"
  [ "$status" -ne 2 ]
  [ -f "$CACHE/compacted" ]
  [ ! -f "$CACHE/notified-pct" ]
  [ ! -f "$CACHE/grace-turn" ]
  [ ! -f "$CACHE/precompact-blocked" ]
  [ -f "$CACHE/state.md" ]
  [ -f "$CACHE/decisions.jsonl" ]
}

@test "no transcript_path: silent noop" {
  run_hook postcompact-marker.sh '{"hook_event_name":"PostCompact"}'
  [ "$status" -ne 2 ]
}

@test "no jq: fail-open" {
  run_hook_env "$(make_no_jq_path)" postcompact-marker.sh "{\"hook_event_name\":\"PostCompact\",\"transcript_path\":\"$TP\"}"
  [ "$status" -ne 2 ]
}
