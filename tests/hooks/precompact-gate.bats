#!/usr/bin/env bats
# precompact-gate.sh の characterization。
# auto 無条件素通し / empty trigger 素通し / manual + 鮮度 + 構造 OK 素通し /
# manual + state 不在・不鮮度・構造 NG でブロック(1 ctx 1 回のみ)。
# 鮮度は state-stamp と現在ターン・使用率の差で決まる(判定は context-paths.sh が単独で持つ)。

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

# 鮮度スタンプと現在ターンを置く($1 = 現在 turn、$2 = stamp 行、$3 = 現在 pct)。
seed_freshness() {
  printf '%s' "$1" > "$CACHE/turn"
  printf '%s' "$2" > "$CACHE/state-stamp"
  printf '{"pct":%s,"transcript_path":"%s","updated_at":%s}' \
    "${3:-40}" "$TP" "$(date +%s)" > "$CACHE/usage.json"
}

@test "manual with fresh valid state: allowed" {
  write_valid_state
  seed_freshness 6 '5 40'
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

@test "manual with state stale by turns: blocked" {
  write_valid_state
  seed_freshness 8 '5 40'
  run_hook precompact-gate.sh "$(compact_json manual)"
  [ "$status" -eq 2 ]
}

@test "manual with state stale by usage growth: blocked" {
  write_valid_state
  seed_freshness 5 '5 30' 45
  run_hook precompact-gate.sh "$(compact_json manual)"
  [ "$status" -eq 2 ]
}

@test "manual without a stamp: blocked (unknown counts as stale)" {
  write_valid_state
  printf '6' > "$CACHE/turn"
  run_hook precompact-gate.sh "$(compact_json manual)"
  [ "$status" -eq 2 ]
}

@test "manual with a stamp from the future: blocked" {
  write_valid_state
  seed_freshness 2 '9 40'
  run_hook precompact-gate.sh "$(compact_json manual)"
  [ "$status" -eq 2 ]
}

@test "manual after a compaction lowered usage: allowed" {
  write_valid_state
  seed_freshness 5 '5 60' 12
  run_hook precompact-gate.sh "$(compact_json manual)"
  [ "$status" -ne 2 ]
}

@test "manual with structurally broken state: blocked" {
  printf '# state file\n\n## Active Plan\nx\n' > "$CACHE/state.md"
  # 鮮度を満たさないと構造検証まで到達せず、validator 呼び出しが消えても緑になる
  seed_freshness 6 '5 40'
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

@test "manual, validator missing: degrades to the freshness check only" {
  rm -f "$VALID_DIR/validate-state.sh"
  printf 'structurally broken but stamped\n' > "$CACHE/state.md"
  seed_freshness 6 '5 40'
  run_hook precompact-gate.sh "$(compact_json manual)"
  [ "$status" -ne 2 ]
}

@test "no jq: allowed (fail-open)" {
  run_hook_env "$(make_no_jq_path)" precompact-gate.sh "$(compact_json manual)"
  [ "$status" -ne 2 ]
}
