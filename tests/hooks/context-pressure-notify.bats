#!/usr/bin/env bats
# context-pressure-notify.sh の characterization。
# 30% 初回提案 / +5 ポイント再通知 / 50% 最終通告 / compacted marker の復帰注入と消費。

load ../helpers/common

CTX="test-ctx-n"

setup() {
  install_hooks
  CACHE="$HOME/.cache/claude-context/$CTX"
  mkdir -p "$CACHE"
  TP="/Users/x/.claude/projects/-p/$CTX.jsonl"
}

write_usage() {
  local ago="${2:-0}"
  printf '{"pct": %s, "transcript_path": "%s", "updated_at": %s}' \
    "$1" "$TP" "$(( $(date +%s) - ago ))" > "$CACHE/usage.json"
}

prompt_json() {
  printf '{"hook_event_name":"UserPromptSubmit","transcript_path":"%s","prompt":"hello"}' "$TP"
}

@test "below 30: silent" {
  write_usage 29
  run_hook context-pressure-notify.sh "$(prompt_json)"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "at 30: orders compact-prep without asking and records notified pct" {
  write_usage 31
  run_hook context-pressure-notify.sh "$(prompt_json)"
  [ "$status" -ne 2 ]
  printf '%s' "$output" | grep -qF 'compact-prep'
  printf '%s' "$output" | grep -qF '自動更新ライン'
  # 30% 台では人間の承認を取りに行かせない(依頼は 50% 以上でだけ)
  printf '%s' "$output" | grep -qF '尋ねずに進めてよい'
  # 免除は state file の更新だけに掛かる(skill 全体への白紙委任にしない)
  printf '%s' "$output" | grep -qF '免除はここまで'
  [ "$(cat "$CACHE/notified-pct")" = "31" ]
}

@test "renotify only after +5 points" {
  write_usage 36
  echo 33 > "$CACHE/notified-pct"
  run_hook context-pressure-notify.sh "$(prompt_json)"
  [ -z "$output" ]
  write_usage 38
  run_hook context-pressure-notify.sh "$(prompt_json)"
  printf '%s' "$output" | grep -qF 'compact-prep'
  [ "$(cat "$CACHE/notified-pct")" = "38" ]
}

@test "at 50: final notice with state file path and grace initialized" {
  write_usage 52
  echo 4 > "$CACHE/turn"
  run_hook context-pressure-notify.sh "$(prompt_json)"
  printf '%s' "$output" | grep -qF '最終通告'
  printf '%s' "$output" | grep -qF 'compact-prep'
  printf '%s' "$output" | grep -qF "$CACHE/state.md"
  # 通知ターン = 猶予ターン(このターンに編集が無くても次ターンから deny)
  [ "$(cat "$CACHE/grace-turn")" = "4" ]
}

@test "at 50: existing grace-turn is not overwritten" {
  write_usage 52
  echo 9 > "$CACHE/turn"
  echo 4 > "$CACHE/grace-turn"
  run_hook context-pressure-notify.sh "$(prompt_json)"
  [ "$(cat "$CACHE/grace-turn")" = "4" ]
}

@test "compacted marker: recovery injection wins and marker consumed" {
  write_usage 5
  touch "$CACHE/compacted"
  run_hook context-pressure-notify.sh "$(prompt_json)"
  [ "$status" -ne 2 ]
  printf '%s' "$output" | grep -qF 'state.md'
  printf '%s' "$output" | grep -qF 'decisions.jsonl'
  printf '%s' "$output" | grep -qF '仮説'
  [ ! -f "$CACHE/compacted" ]
}

@test "stale usage: silent (fail-open)" {
  write_usage 55 2000
  run_hook context-pressure-notify.sh "$(prompt_json)"
  [ -z "$output" ]
}

@test "no usage: silent (fail-open)" {
  run_hook context-pressure-notify.sh "$(prompt_json)"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "no jq: silent (fail-open)" {
  write_usage 55
  run_hook_env "$(make_no_jq_path)" context-pressure-notify.sh "$(prompt_json)"
  [ "$status" -ne 2 ]
}
