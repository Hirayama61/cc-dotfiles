#!/usr/bin/env bats
# evolve-nudge-on-stop.sh の E2E。
# ローカル進化の区切りナッジ(Stop hook)。発火条件 = (a) 同 ctx で編集発生
# (cs-injected-* フラグ)or (b) candidates/ に滞留候補。1 ctx 1 回で、それ以外は
# fail-open で素通り(exit 0・出力なし)。block は exit 0 + top-level JSON。

load ../helpers/common

setup() {
  install_hooks
}

# ctx にコード編集済みシグナル(cs-injected フラグ)を置く。
# キーは flag-paths.sh と同じ導出(state dir + cs-injected-<ctx>--<scope>)。
_seed_edited() {
  local ctx="$1"
  local dir="$HOME/.local/state/claude-sessions"
  mkdir -p "$dir"
  touch "$dir/cs-injected-${ctx}--global"
}

# candidates に滞留候補を置く。
_seed_candidate() {
  mkdir -p "$HOME/.claude-evolution/candidates/skills/sample-skill"
  printf '# sample\n' >"$HOME/.claude-evolution/candidates/skills/sample-skill/SKILL.md"
}

assert_block() {
  jq -e '.decision == "block" and (.reason | type == "string" and length > 0)' <<<"$output" >/dev/null
}

@test "no nudge when no edits and no candidates" {
  run_hook evolve-nudge-on-stop.sh \
    '{"stop_hook_active":false,"transcript_path":"/tmp/tp/sess-a.jsonl"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "nudges once when edits happened in this ctx" {
  _seed_edited sess-b
  run_hook evolve-nudge-on-stop.sh \
    '{"stop_hook_active":false,"transcript_path":"/tmp/tp/sess-b.jsonl"}'
  [ "$status" -eq 0 ]
  assert_block
}

@test "second stop in same ctx does not nudge again (1 per ctx)" {
  _seed_edited sess-c
  run_hook evolve-nudge-on-stop.sh \
    '{"stop_hook_active":false,"transcript_path":"/tmp/tp/sess-c.jsonl"}'
  assert_block
  run_hook evolve-nudge-on-stop.sh \
    '{"stop_hook_active":false,"transcript_path":"/tmp/tp/sess-c.jsonl"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "nudges on pending candidates even without edits, reason mentions count" {
  _seed_candidate
  run_hook evolve-nudge-on-stop.sh \
    '{"stop_hook_active":false,"transcript_path":"/tmp/tp/sess-d.jsonl"}'
  [ "$status" -eq 0 ]
  assert_block
  jq -e '.reason | contains("1 件")' <<<"$output" >/dev/null
}

@test "no nudge when stop_hook_active is true (1 per stop chain)" {
  _seed_edited sess-e
  run_hook evolve-nudge-on-stop.sh \
    '{"stop_hook_active":true,"transcript_path":"/tmp/tp/sess-e.jsonl"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no nudge when ctx is missing (fail-open)" {
  _seed_candidate
  run_hook evolve-nudge-on-stop.sh '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "rearm-coding-standards clears the nudged flag (re-nudge after clear/compact)" {
  _seed_edited sess-f
  run_hook evolve-nudge-on-stop.sh \
    '{"stop_hook_active":false,"transcript_path":"/tmp/tp/sess-f.jsonl"}'
  assert_block
  run_hook rearm-coding-standards.sh '{"transcript_path":"/tmp/tp/sess-f.jsonl"}'
  [ "$status" -eq 0 ]
  _seed_edited sess-f
  run_hook evolve-nudge-on-stop.sh \
    '{"stop_hook_active":false,"transcript_path":"/tmp/tp/sess-f.jsonl"}'
  assert_block
}

@test "fail-open when jq is absent" {
  _seed_edited sess-g
  run_hook_env "$(make_no_jq_path)" evolve-nudge-on-stop.sh \
    '{"stop_hook_active":false,"transcript_path":"/tmp/tp/sess-g.jsonl"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "session_id fallback works when transcript_path is absent" {
  _seed_edited sess-h
  run_hook evolve-nudge-on-stop.sh \
    '{"stop_hook_active":false,"session_id":"sess-h"}'
  [ "$status" -eq 0 ]
  assert_block
}
