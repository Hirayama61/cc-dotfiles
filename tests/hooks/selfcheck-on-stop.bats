#!/usr/bin/env bats
# selfcheck-on-stop.sh の E2E。
# ファントムツール呼び出し復帰用の Stop フック。未完(pending/in_progress)タスクが
# 残った停止のときだけ中立な block(自己チェック)を出し、それ以外は fail-open で
# 素通り(exit 0・出力なし)する。block は exit 2 でなく exit 0 + top-level JSON。

load ../helpers/common

setup() {
  install_hooks
}

# 指定 session の tasks dir に1件タスクを置く(HOME は install_hooks で一時 HOME に差替済)。
_seed_task() {
  local sid="$1" status="$2"
  mkdir -p "$HOME/.claude/tasks/$sid"
  printf '{"id":"1","subject":"x","status":"%s"}\n' "$status" \
    >"$HOME/.claude/tasks/$sid/1.json"
}

# block 出力が Stop の正典(top-level decision=block + 非空 reason)であることを構造で検証。
assert_block() {
  jq -e '.decision == "block" and (.reason | type == "string" and length > 0)' <<<"$output" >/dev/null
}

@test "blocks (self-check) when an in_progress task remains" {
  _seed_task sess-a in_progress
  run_hook selfcheck-on-stop.sh '{"stop_hook_active":false,"session_id":"sess-a"}'
  [ "$status" -eq 0 ]
  assert_block
}

@test "blocks when a pending task remains" {
  _seed_task sess-b pending
  run_hook selfcheck-on-stop.sh '{"stop_hook_active":false,"session_id":"sess-b"}'
  [ "$status" -eq 0 ]
  assert_block
}

@test "no block when all tasks are completed" {
  _seed_task sess-c completed
  run_hook selfcheck-on-stop.sh '{"stop_hook_active":false,"session_id":"sess-c"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "aggregation: 2 completed + 1 pending across files blocks" {
  mkdir -p "$HOME/.claude/tasks/sess-mix"
  printf '{"id":"1","status":"completed"}\n'   >"$HOME/.claude/tasks/sess-mix/1.json"
  printf '{"id":"2","status":"completed"}\n'   >"$HOME/.claude/tasks/sess-mix/2.json"
  printf '{"id":"3","status":"pending"}\n'     >"$HOME/.claude/tasks/sess-mix/3.json"
  run_hook selfcheck-on-stop.sh '{"stop_hook_active":false,"session_id":"sess-mix"}'
  [ "$status" -eq 0 ]
  assert_block
}

@test "no block when tasks dir exists but has no json files" {
  mkdir -p "$HOME/.claude/tasks/sess-empty"
  run_hook selfcheck-on-stop.sh '{"stop_hook_active":false,"session_id":"sess-empty"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no block when stop_hook_active is true (1 nudge per chain)" {
  _seed_task sess-d in_progress
  run_hook selfcheck-on-stop.sh '{"stop_hook_active":true,"session_id":"sess-d"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no block when session has no tasks dir" {
  run_hook selfcheck-on-stop.sh '{"stop_hook_active":false,"session_id":"no-such"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no block when session_id is absent" {
  run_hook selfcheck-on-stop.sh '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fail-open on corrupt task json (no crash, no block)" {
  mkdir -p "$HOME/.claude/tasks/sess-e"
  printf '{ broken json (' >"$HOME/.claude/tasks/sess-e/1.json"
  run_hook selfcheck-on-stop.sh '{"stop_hook_active":false,"session_id":"sess-e"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "partial corruption: healthy in_progress + broken json still blocks" {
  _seed_task sess-h in_progress
  printf '{ broken json (' >"$HOME/.claude/tasks/sess-h/2.json"
  run_hook selfcheck-on-stop.sh '{"stop_hook_active":false,"session_id":"sess-h"}'
  [ "$status" -eq 0 ]
  assert_block
}

@test "rejects path traversal in session_id (no escape, no block)" {
  # HOME 外に未完タスクを置き、session_id の ../ で到達しないことを保証する。
  local outside="$BATS_TEST_TMPDIR/outside/tasks/leak"
  mkdir -p "$outside"
  printf '{"id":"1","status":"in_progress"}\n' >"$outside/1.json"
  run_hook selfcheck-on-stop.sh \
    '{"stop_hook_active":false,"session_id":"../../outside/tasks/leak"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "rejects session_id with slash (no block)" {
  run_hook selfcheck-on-stop.sh '{"stop_hook_active":false,"session_id":"a/b"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fail-open when jq is absent" {
  _seed_task sess-f in_progress
  run_hook_env "$(make_no_jq_path)" selfcheck-on-stop.sh \
    '{"stop_hook_active":false,"session_id":"sess-f"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fail-open: exits 0 (never blocks via exit 2) with incomplete task" {
  _seed_task sess-g in_progress
  run_hook selfcheck-on-stop.sh '{"stop_hook_active":false,"session_id":"sess-g"}'
  [ "$status" -eq 0 ]
}
