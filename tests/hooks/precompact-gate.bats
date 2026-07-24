#!/usr/bin/env bats
# precompact-gate.sh の characterization。
# auto 無条件素通し / empty trigger 素通し / manual + 鮮度 + 構造 OK 素通し /
# manual + state 不在・不鮮度・構造 NG でブロック(1 ctx 1 回のみ)。

load ../helpers/common

CTX="test-ctx-p"

setup() {
  install_hooks
  # precompact-gate は validator を $HOME/.claude/skills/... から借用する。
  # install_hooks は skills を複製しないため手動で一時 HOME へ据える。
  VALID_DIR="$HOME/.claude/skills/compact-prep/scripts"
  mkdir -p "$VALID_DIR"
  install -m 755 "$REPO_ROOT/home/dot_claude/skills/compact-prep/scripts/executable_validate-state.sh" \
    "$VALID_DIR/validate-state.sh"
  CACHE="$HOME/.cache/claude-context/$CTX"
  mkdir -p "$CACHE"
  TP="/Users/x/.claude/projects/-p/$CTX.jsonl"
}

compact_json() {
  printf '{"hook_event_name":"PreCompact","transcript_path":"%s","trigger":"%s"}' "$TP" "$1"
}

write_valid_state() {
  cat > "$CACHE/state.md" <<'EOF'
# state file

## Active Plan
plan file X, phase 2

## Session Decisions
adopted A over B because C

## Constraints and Blockers
なし

## Worker Topology
なし

## Editing Files
なし
EOF
}

@test "trigger auto: always allowed" {
  run_hook precompact-gate.sh "$(compact_json auto)"
  [ "$status" -ne 2 ]
}

@test "empty trigger: allowed (fail-open)" {
  run_hook precompact-gate.sh "{\"hook_event_name\":\"PreCompact\",\"transcript_path\":\"$TP\"}"
  [ "$status" -ne 2 ]
}

@test "manual with fresh valid state: allowed" {
  write_valid_state
  run_hook precompact-gate.sh "$(compact_json manual)"
  [ "$status" -ne 2 ]
}

@test "manual without state: blocked once then allowed" {
  run_hook precompact-gate.sh "$(compact_json manual)"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'compact-prep'
  # 2 回目は素通し(恒久ブロックにしない)
  run_hook precompact-gate.sh "$(compact_json manual)"
  [ "$status" -ne 2 ]
}

@test "manual with stale state: blocked" {
  write_valid_state
  touch -t 202001010000 "$CACHE/state.md"
  run_hook precompact-gate.sh "$(compact_json manual)"
  [ "$status" -eq 2 ]
}

@test "manual with structurally broken state: blocked" {
  printf '# state file\n\n## Active Plan\nx\n' > "$CACHE/state.md"
  run_hook precompact-gate.sh "$(compact_json manual)"
  [ "$status" -eq 2 ]
}

@test "manual without state, marker unwritable: allowed (fail-open, no permanent block)" {
  # ctx dir を実ファイルで塞ぎ、ensure/touch を失敗させる(marker を書けない環境の再現)。
  # marker を書けないままブロックすると「2 回目は通る」が成立せず恒久ブロックになるため
  # ブロック自体を諦めることを固定する。
  rm -rf "$CACHE"
  touch "$CACHE"
  run_hook precompact-gate.sh "$(compact_json manual)"
  [ "$status" -ne 2 ]
}

@test "manual, validator missing: degrades to mtime only" {
  rm -f "$VALID_DIR/validate-state.sh"
  printf 'anything fresh\n' > "$CACHE/state.md"
  run_hook precompact-gate.sh "$(compact_json manual)"
  [ "$status" -ne 2 ]
}

@test "no jq: allowed (fail-open)" {
  run_hook_env "$(make_no_jq_path)" precompact-gate.sh "$(compact_json manual)"
  [ "$status" -ne 2 ]
}
