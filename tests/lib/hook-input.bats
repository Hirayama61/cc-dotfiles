#!/usr/bin/env bats
# hook-input.sh の単体テスト。共通ヘルパの抽出と fail-open を固定する。

load ../helpers/common

setup() {
  install_hooks
  LIB="$HOME/.claude/hooks/lib/hook-input.sh"
  # shellcheck source=/dev/null
  source "$LIB"
}

@test "hook_init returns 0 and HOOK_INPUT holds stdin when jq present" {
  output="$(printf '%s' '{"tool_name":"Bash"}' | { hook_init; printf '%s' "$HOOK_INPUT"; })"
  [ "$output" = '{"tool_name":"Bash"}' ]
}

@test "hook_init returns 1 when jq absent (fail-open)" {
  nojq="$(make_no_jq_path)"
  run env PATH="$nojq" bash -c 'source "$1"; printf x | hook_init' _ "$LIB"
  [ "$status" -eq 1 ]
}

@test "hook_field extracts nested path" {
  HOOK_INPUT='{"tool_input":{"command":"ls -la"}}'
  run hook_field '.tool_input.command'
  [ "$status" -eq 0 ]
  [ "$output" = "ls -la" ]
}

@test "hook_field returns empty for missing key (// empty)" {
  HOOK_INPUT='{}'
  run hook_field '.tool_input.command'
  [ "$output" = "" ]
}

@test "hook_field returns empty for broken JSON (fail-open)" {
  HOOK_INPUT='not json {{'
  run hook_field '.tool_name'
  [ "$output" = "" ]
}

@test "hook_field_raw does not collapse false" {
  HOOK_INPUT='{"x":false}'
  run hook_field_raw '.x'
  [ "$output" = "false" ]
}

@test "hook_command shortcut" {
  HOOK_INPUT='{"tool_input":{"command":"git push"}}'
  run hook_command
  [ "$output" = "git push" ]
}

@test "hook_tool_name shortcut" {
  HOOK_INPUT='{"tool_name":"Edit"}'
  run hook_tool_name
  [ "$output" = "Edit" ]
}

@test "hook_file_path shortcut" {
  HOOK_INPUT='{"tool_input":{"file_path":"/tmp/x.txt"}}'
  run hook_file_path
  [ "$output" = "/tmp/x.txt" ]
}

@test "hook_cwd and hook_session_id shortcuts" {
  HOOK_INPUT='{"cwd":"/repo","session_id":"sid123"}'
  run hook_cwd
  [ "$output" = "/repo" ]
  run hook_session_id
  [ "$output" = "sid123" ]
}

@test "source_hook_lib loads a valid lib (returns 0)" {
  run source_hook_lib flag-paths.sh
  [ "$status" -eq 0 ]
}

@test "source_hook_lib returns 1 for missing lib" {
  run source_hook_lib definitely-not-here.sh
  [ "$status" -eq 1 ]
}

@test "source_hook_lib returns 1 for corrupt lib (fail-open)" {
  printf '%s' '{ broken bash (' >"$HOME/.claude/hooks/lib/broken-test.sh"
  run source_hook_lib broken-test.sh
  [ "$status" -eq 1 ]
}
