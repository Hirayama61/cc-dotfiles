#!/usr/bin/env bats
# compact-prep/scripts/validate-state.sh の characterization。
# 5 見出しの存在・順序・各節非空の検査。exit 0 = PASS / exit 1 = FAIL(2 は使わない)。

load ../helpers/common

setup() {
  VALIDATOR="$REPO_ROOT/home/dot_claude/skills/compact-prep/scripts/executable_validate-state.sh"
  STATE="$BATS_TEST_TMPDIR/state.md"
}

write_full() {
  cat > "$STATE" <<'EOF'
# state file

## Active Plan
plan X phase 2

## Session Decisions
adopted A, rejected B because C

## Constraints and Blockers
なし

## Worker Topology
なし

## Editing Files
なし
EOF
}

@test "valid state: PASS" {
  write_full
  run bash "$VALIDATOR" "$STATE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

@test "missing heading: FAIL names it" {
  write_full
  grep -v '^## Worker Topology$' "$STATE" > "$STATE.t" && mv "$STATE.t" "$STATE"
  run bash "$VALIDATOR" "$STATE"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'Worker Topology'
}

@test "empty section: FAIL" {
  write_full
  # Session Decisions の本文を空にする
  sed -i '' 's/^adopted A, rejected B because C$//' "$STATE"
  run bash "$VALIDATOR" "$STATE"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'Session Decisions'
}

@test "wrong order: FAIL" {
  cat > "$STATE" <<'EOF'
## Session Decisions
x

## Active Plan
y

## Constraints and Blockers
z

## Worker Topology
w

## Editing Files
v
EOF
  run bash "$VALIDATOR" "$STATE"
  [ "$status" -eq 1 ]
}

@test "missing file: FAIL not exit 2" {
  run bash "$VALIDATOR" "$BATS_TEST_TMPDIR/nope.md"
  [ "$status" -eq 1 ]
}

@test "no arg: FAIL" {
  run bash "$VALIDATOR"
  [ "$status" -eq 1 ]
}
