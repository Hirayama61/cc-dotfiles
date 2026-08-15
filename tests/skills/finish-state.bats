#!/usr/bin/env bats
# finish-state.sh の契約。state file を確定し鮮度スタンプを打つ compact-prep 手順 7。
#
# 固定する不変条件:
#   - 構造検証に通らなければスタンプを打たず、既存スタンプも消す
#     (残すと壊れた state が許容ターン数のあいだ「新鮮」のまま沈黙する)
#   - ターンが読めなければ同様に打たず消す(不明を新鮮側へ倒さない)
#   - pct は副条件。読めなくてもスタンプ自体は打つ(圧縮直後は usage.json が無い)
#   - 引数は cache 配下 + basename state.md のときだけ受ける(削除を伴うため)

load ../helpers/common

CTX="ctx-finish"

setup() {
  install_hooks
  SCRIPTS="$HOME/.claude/skills/compact-prep/scripts"
  mkdir -p "$SCRIPTS"
  local src="$REPO_ROOT/home/dot_claude/skills/compact-prep/scripts"
  install -m 755 "$src/executable_validate-state.sh" "$SCRIPTS/validate-state.sh"
  install -m 755 "$src/executable_finish-state.sh" "$SCRIPTS/finish-state.sh"

  CACHE="$HOME/.cache/claude-context/$CTX"
  mkdir -p "$CACHE"
  chmod 700 "$CACHE"
  STATE="$CACHE/state.md"
  STAMP="$CACHE/state-stamp"
}

write_valid_state() {
  cat > "$STATE" <<'EOF'
# state file

## Active Plan
plan X, phase 2

## Session Decisions
adopted A over B

## Constraints and Blockers
なし

## Worker Topology
なし

## Editing Files
なし
EOF
}

run_finish() {
  run bash "$SCRIPTS/finish-state.sh" "${1-$STATE}"
}

@test "stamps turn and pct when structure and both values are available" {
  write_valid_state
  printf '7' > "$CACHE/turn"
  printf '{"pct":42.7,"updated_at":%s}' "$(date +%s)" > "$CACHE/usage.json"
  run_finish
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
  [ "$(cat "$STAMP")" = "7 42" ]
}

@test "stamps an unknown pct when usage.json is too old to represent the current usage" {
  write_valid_state
  printf '7' > "$CACHE/turn"
  printf '{"pct":55,"updated_at":1}' > "$CACHE/usage.json"
  run_finish
  [ "$status" -eq 0 ]
  # 実際より高い値を焼くと、読み側が「現在 pct が stamp より低い = 圧縮された」と見て
  # 使用率次元を外し続ける(古さを検知できなくなる)
  [ "$(cat "$STAMP")" = "7 -" ]
}

@test "stamps with an unknown pct when usage.json is absent" {
  write_valid_state
  printf '7' > "$CACHE/turn"
  run_finish
  [ "$status" -eq 0 ]
  [ "$(cat "$STAMP")" = "7 -" ]
}

@test "structural failure removes an existing stamp" {
  printf '# state file\n\n## Active Plan\nx\n' > "$STATE"
  printf '7' > "$CACHE/turn"
  printf '5 40' > "$STAMP"
  run_finish
  [ "$status" -eq 1 ]
  [[ "$output" == FAIL:* ]]
  [ ! -e "$STAMP" ]
}

@test "an unreadable turn counter removes an existing stamp" {
  write_valid_state
  printf '5 40' > "$STAMP"
  run_finish
  [ "$status" -eq 1 ]
  [ ! -e "$STAMP" ]
}

@test "a non-numeric turn counter is refused" {
  write_valid_state
  printf 'abc' > "$CACHE/turn"
  run_finish
  [ "$status" -eq 1 ]
  [ ! -e "$STAMP" ]
}

@test "refuses a path outside the cache without touching anything" {
  local outside="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$outside"
  printf 'x\n' > "$outside/state.md"
  printf '5 40' > "$outside/state-stamp"
  run bash "$SCRIPTS/finish-state.sh" "$outside/state.md"
  [ "$status" -eq 1 ]
  [ -e "$outside/state-stamp" ]
}

@test "refuses a ctx dir nested deeper than the cache root" {
  local nested="$CACHE/deeper"
  mkdir -p "$nested"
  printf 'x\n' > "$nested/state.md"
  printf '7' > "$nested/turn"
  run bash "$SCRIPTS/finish-state.sh" "$nested/state.md"
  [ "$status" -eq 1 ]
  [ ! -e "$nested/state-stamp" ]
}

@test "refuses when usage.json points at a different ctx" {
  write_valid_state
  printf '7' > "$CACHE/turn"
  printf '5 40' > "$STAMP"
  printf '{"pct":42,"transcript_path":"/p/other-ctx.jsonl","updated_at":%s}' "$(date +%s)" > "$CACHE/usage.json"
  run_finish
  [ "$status" -eq 1 ]
  # 取り違えの疑いがある時は消しも書きもしない
  [ "$(cat "$STAMP")" = "5 40" ]
}

@test "accepts when usage.json points at this ctx" {
  write_valid_state
  printf '7' > "$CACHE/turn"
  printf '{"pct":42,"transcript_path":"/p/%s.jsonl","updated_at":%s}' "$CTX" "$(date +%s)" > "$CACHE/usage.json"
  run_finish
  [ "$status" -eq 0 ]
  [ "$(cat "$STAMP")" = "7 42" ]
}

@test "refuses a file that is not named state.md" {
  write_valid_state
  printf '7' > "$CACHE/turn"
  cp "$STATE" "$CACHE/other.md"
  run bash "$SCRIPTS/finish-state.sh" "$CACHE/other.md"
  [ "$status" -eq 1 ]
  [ ! -e "$STAMP" ]
}

@test "refuses a missing argument" {
  run bash "$SCRIPTS/finish-state.sh"
  [ "$status" -eq 1 ]
}

@test "the stamp it writes is accepted as fresh by the shared freshness check" {
  write_valid_state
  printf '7' > "$CACHE/turn"
  printf '{"pct":42,"updated_at":%s}' "$(date +%s)" > "$CACHE/usage.json"
  run_finish
  [ "$status" -eq 0 ]
  run bash -c '. "$1"; claude_ctx_state_is_fresh "$2"' _ \
    "$HOME/.claude/hooks/lib/context-paths.sh" "$CTX"
  [ "$status" -eq 0 ]
}

@test "leaves no temporary file behind" {
  write_valid_state
  printf '7' > "$CACHE/turn"
  run_finish
  # 成果物が出たことを先に見る。見ないと、tmp 書込へ到達せず落ちた実装でも
  # 「残骸なし」が成立してこのテストだけ緑になる。
  [ "$status" -eq 0 ]
  [ -e "$STAMP" ]
  # 一時ファイル名で固定すると、実装が別名に変えた時に何も検証せず緑になる。
  # find は cd を挟まないので、収集そのものの失敗を成功と取り違えない。
  local leftovers
  leftovers="$(find "$CACHE" -mindepth 1 -maxdepth 1 \
    ! -name state.md ! -name turn ! -name state-stamp)"
  [ -z "$leftovers" ]
}
