#!/usr/bin/env bats
# stop-nudge.sh の E2E。
# 停止時ナッジの単一入口。独立した 2 条件(未完タスクの残存 / state file が古い)を
# 評価し、成立したものを 1 つの block の reason へ連結する。それ以外は fail-open で
# 素通り(出力なし)。
#
# この hook は exit 2 を使わない(Stop の遮断は stdout の top-level JSON)。よって
# status は一律 `-ne 2` で検査し、遮断したかどうかは output 側で判定する。
# status を `-eq 0` で縛ると、jq 不在の 127 のような非ブロッキング終了で
# 「遮断された」と誤って赤くなる。

load ../helpers/common

CTX="test-ctx-stop"

setup() {
  install_hooks
  # 構造検証は compact-prep の validator を借用する。install_hooks は skills を
  # 複製しないので手動で据える(据えないと検証分岐が一度も走らない)。
  VALID_DIR="$HOME/.claude/skills/compact-prep/scripts"
  mkdir -p "$VALID_DIR"
  install -m 755 "$REPO_ROOT/home/dot_claude/skills/compact-prep/scripts/executable_validate-state.sh" \
    "$VALID_DIR/validate-state.sh"
  CACHE="$HOME/.cache/claude-context/$CTX"
  mkdir -p "$CACHE"
  chmod 700 "$CACHE"
  TP="/Users/x/.claude/projects/-p/$CTX.jsonl"
}

# 指定 session の tasks dir に1件タスクを置く(HOME は install_hooks で一時 HOME に差替済)。
_seed_task() {
  local sid="$1" status="$2"
  mkdir -p "$HOME/.claude/tasks/$sid"
  printf '{"id":"1","subject":"x","status":"%s"}\n' "$status" \
    >"$HOME/.claude/tasks/$sid/1.json"
}

# 構造検証を通る state file を置く。
_seed_state() {
  cat >"$CACHE/state.md" <<'EOF'
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

# usage.json と turn を置く。$1 = pct、$2 = turn、$3 = updated_at の now からの引き算(省略時 0)。
_seed_usage() {
  local pct="$1" turn="$2" age="${3:-0}"
  printf '{"pct":%s,"transcript_path":"%s","updated_at":%s}' \
    "$pct" "$TP" "$(( $(date +%s) - age ))" >"$CACHE/usage.json"
  printf '%s' "$turn" >"$CACHE/turn"
}

stop_json() {
  printf '{"hook_event_name":"Stop","stop_hook_active":%s,"session_id":"%s","transcript_path":"%s"}' \
    "$1" "$2" "$TP"
}

TASK_MARK="未完了のタスク"
COMPACT_MARK="compact-prep skill を実行"

# block 出力が Stop の正典(top-level decision=block + 非空 reason)であることを構造で検証。
assert_block() {
  jq -e '.decision == "block" and (.reason | type == "string" and length > 0)' <<<"$output" >/dev/null
}

assert_reason_has() {
  jq -e --arg s "$1" '.reason | contains($s)' <<<"$output" >/dev/null
}

assert_reason_lacks() {
  local probe
  probe="$(jq -r --arg s "$1" '.reason | contains($s)' <<<"$output" 2>/dev/null || echo error)"
  [ "$probe" = "false" ]
}

# --- 未完タスク条件(旧 selfcheck-on-stop の characterization) ---

@test "blocks (self-check) when an in_progress task remains" {
  _seed_task sess-a in_progress
  run_hook stop-nudge.sh "$(stop_json false sess-a)"
  [ "$status" -ne 2 ]
  assert_block
  assert_reason_has "$TASK_MARK"
}

@test "blocks when a pending task remains" {
  _seed_task sess-b pending
  run_hook stop-nudge.sh "$(stop_json false sess-b)"
  [ "$status" -ne 2 ]
  assert_block
}

@test "no block when all tasks are completed" {
  _seed_task sess-c completed
  run_hook stop-nudge.sh "$(stop_json false sess-c)"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "aggregation: 2 completed + 1 pending across files blocks" {
  mkdir -p "$HOME/.claude/tasks/sess-mix"
  printf '{"id":"1","status":"completed"}\n'   >"$HOME/.claude/tasks/sess-mix/1.json"
  printf '{"id":"2","status":"completed"}\n'   >"$HOME/.claude/tasks/sess-mix/2.json"
  printf '{"id":"3","status":"pending"}\n'     >"$HOME/.claude/tasks/sess-mix/3.json"
  run_hook stop-nudge.sh "$(stop_json false sess-mix)"
  [ "$status" -ne 2 ]
  assert_block
}

@test "no block when tasks dir exists but has no json files" {
  mkdir -p "$HOME/.claude/tasks/sess-empty"
  run_hook stop-nudge.sh "$(stop_json false sess-empty)"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "no block when stop_hook_active is true (1 nudge per chain)" {
  _seed_task sess-d in_progress
  _seed_usage 60 10
  run_hook stop-nudge.sh "$(stop_json true sess-d)"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "no block when session has no tasks dir" {
  run_hook stop-nudge.sh "$(stop_json false no-such)"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "no block when session_id is absent" {
  run_hook stop-nudge.sh '{"stop_hook_active":false}'
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "fail-open on corrupt task json (no crash, no block)" {
  mkdir -p "$HOME/.claude/tasks/sess-e"
  printf '{ broken json (' >"$HOME/.claude/tasks/sess-e/1.json"
  run_hook stop-nudge.sh "$(stop_json false sess-e)"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "partial corruption: healthy in_progress + broken json still blocks" {
  _seed_task sess-h in_progress
  printf '{ broken json (' >"$HOME/.claude/tasks/sess-h/2.json"
  run_hook stop-nudge.sh "$(stop_json false sess-h)"
  [ "$status" -ne 2 ]
  assert_block
}

@test "rejects path traversal in session_id (no escape, no block)" {
  # HOME 外に未完タスクを置き、session_id の ../ で到達しないことを保証する。
  local outside="$BATS_TEST_TMPDIR/outside/tasks/leak"
  mkdir -p "$outside"
  printf '{"id":"1","status":"in_progress"}\n' >"$outside/1.json"
  run_hook stop-nudge.sh \
    '{"stop_hook_active":false,"session_id":"../../outside/tasks/leak"}'
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "rejects session_id with slash (no block)" {
  run_hook stop-nudge.sh '{"stop_hook_active":false,"session_id":"a/b"}'
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "fail-open when jq is absent" {
  _seed_task sess-f in_progress
  run_hook_env "$(make_no_jq_path)" stop-nudge.sh "$(stop_json false sess-f)"
  # 遮断は exit 2 のみ。jq 不在の 127 は非ブロッキングなので status では判定しない
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "fail-open: never blocks via exit 2 with incomplete task" {
  _seed_task sess-g in_progress
  run_hook stop-nudge.sh "$(stop_json false sess-g)"
  [ "$status" -ne 2 ]
}

# --- compact-prep 条件 ---

@test "compact: blocks when state file is absent at 30 percent" {
  _seed_usage 30 5
  run_hook stop-nudge.sh "$(stop_json false sess-none)"
  [ "$status" -ne 2 ]
  assert_block
  assert_reason_has "$COMPACT_MARK"
}

@test "compact: blocks when turn advanced beyond the allowance" {
  _seed_state
  _seed_usage 40 8
  printf '5 40' >"$CACHE/state-stamp"
  run_hook stop-nudge.sh "$(stop_json false sess-none)"
  [ "$status" -ne 2 ]
  assert_reason_has "$COMPACT_MARK"
}

@test "compact: blocks when usage grew beyond the allowance within one turn" {
  _seed_state
  _seed_usage 45 5
  printf '5 30' >"$CACHE/state-stamp"
  run_hook stop-nudge.sh "$(stop_json false sess-none)"
  [ "$status" -ne 2 ]
  assert_reason_has "$COMPACT_MARK"
}

@test "compact: a fresh stamp over a structurally broken state still nudges" {
  # precompact-gate と同じ構造検証を通す(通さないと両者の言う「新鮮」がずれる)
  printf '# state file\n\n## Active Plan\nx\n' >"$CACHE/state.md"
  _seed_usage 40 6
  printf '5 40' >"$CACHE/state-stamp"
  run_hook stop-nudge.sh "$(stop_json false sess-broken)"
  [ "$status" -ne 2 ]
  assert_reason_has "$COMPACT_MARK"
}

@test "compact: no block when the stamp is fresh in both dimensions" {
  _seed_state
  _seed_usage 35 6
  printf '5 30' >"$CACHE/state-stamp"
  run_hook stop-nudge.sh "$(stop_json false sess-none)"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "compact: pct unknown in the stamp falls back to the turn dimension" {
  _seed_state
  _seed_usage 90 6
  printf '5 -' >"$CACHE/state-stamp"
  run_hook stop-nudge.sh "$(stop_json false sess-none)"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "compact: no block below 30 percent even with a stale state" {
  _seed_usage 29 99
  run_hook stop-nudge.sh "$(stop_json false sess-none)"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "compact: no block when usage.json is absent" {
  run_hook stop-nudge.sh "$(stop_json false sess-none)"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "compact: no block when usage.json is stale" {
  _seed_usage 60 9 2000
  run_hook stop-nudge.sh "$(stop_json false sess-none)"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "compact: no block right after a compaction (compacted marker present)" {
  _seed_usage 60 9
  touch "$CACHE/compacted"
  run_hook stop-nudge.sh "$(stop_json false sess-none)"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "compact: no block when transcript_path is absent" {
  _seed_usage 60 9
  run_hook stop-nudge.sh '{"stop_hook_active":false,"session_id":"sess-none"}'
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "compact: negative turn difference counts as stale, not fresh" {
  _seed_state
  _seed_usage 40 2
  printf '9 40' >"$CACHE/state-stamp"
  run_hook stop-nudge.sh "$(stop_json false sess-none)"
  [ "$status" -ne 2 ]
  assert_reason_has "$COMPACT_MARK"
}

@test "compact: usage dropping after a compaction is not treated as stale" {
  _seed_state
  _seed_usage 12 6
  printf '5 60' >"$CACHE/state-stamp"
  run_hook stop-nudge.sh "$(stop_json false sess-none)"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

# --- 打ち止めと連結 ---

@test "both conditions produce a single block carrying both instructions" {
  _seed_task sess-both in_progress
  _seed_usage 60 9
  run_hook stop-nudge.sh "$(stop_json false sess-both)"
  [ "$status" -ne 2 ]
  assert_block
  # JSON オブジェクトが 1 つだけであること(2 本の block を返していない)
  [ "$(jq -s 'length' <<<"$output")" -eq 1 ]
  assert_reason_has "$TASK_MARK"
  assert_reason_has "$COMPACT_MARK"
}

@test "the compact nudge is capped at once per user turn, the task nudge is not" {
  _seed_task sess-twice in_progress
  _seed_usage 60 9
  run_hook stop-nudge.sh "$(stop_json false sess-twice)"
  assert_reason_has "$COMPACT_MARK"

  run_hook stop-nudge.sh "$(stop_json false sess-twice)"
  [ "$status" -ne 2 ]
  assert_block
  assert_reason_has "$TASK_MARK"
  assert_reason_lacks "$COMPACT_MARK"
}

@test "a new user turn re-arms the compact nudge" {
  _seed_usage 60 9
  run_hook stop-nudge.sh "$(stop_json false sess-rearm)"
  assert_reason_has "$COMPACT_MARK"

  printf '10' >"$CACHE/turn"
  run_hook stop-nudge.sh "$(stop_json false sess-rearm)"
  [ "$status" -ne 2 ]
  assert_reason_has "$COMPACT_MARK"
}

@test "the compact nudge goes quiet after three turns without the state going fresh" {
  _seed_usage 60 1
  local turn
  for turn in 1 2 3; do
    printf '%s' "$turn" >"$CACHE/turn"
    run_hook stop-nudge.sh "$(stop_json false sess-limit)"
    assert_reason_has "$COMPACT_MARK"
  done
  printf '4' >"$CACHE/turn"
  run_hook stop-nudge.sh "$(stop_json false sess-limit)"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "the nudge budget is restored once the state becomes fresh again" {
  _seed_usage 60 1
  local turn
  for turn in 1 2 3; do
    printf '%s' "$turn" >"$CACHE/turn"
    run_hook stop-nudge.sh "$(stop_json false sess-restore)"
  done
  # 新鮮になった停止で連続回数が捨てられる
  _seed_state
  printf '4' >"$CACHE/turn"
  printf '4 60' >"$CACHE/state-stamp"
  run_hook stop-nudge.sh "$(stop_json false sess-restore)"
  [ -z "$output" ]

  rm -f "$CACHE/state.md"
  printf '5' >"$CACHE/turn"
  run_hook stop-nudge.sh "$(stop_json false sess-restore)"
  assert_reason_has "$COMPACT_MARK"
}

@test "the compact nudge scopes its approval exemption to the state file" {
  _seed_usage 60 9
  run_hook stop-nudge.sh "$(stop_json false sess-scope)"
  assert_reason_has "この state file の更新に限り"
  assert_reason_has "免除はここまで"
}

@test "a corrupt cap file is treated as no cap rather than silencing the nudge" {
  _seed_usage 60 9
  printf 'abc xyz' >"$CACHE/stop-nudged-turn"
  run_hook stop-nudge.sh "$(stop_json false sess-badcap)"
  assert_reason_has "$COMPACT_MARK"
  [ "$(cat "$CACHE/stop-nudged-turn")" = "9 1" ]
}

@test "an empty cap file restarts the count rather than blocking forever" {
  _seed_usage 60 9
  : >"$CACHE/stop-nudged-turn"
  run_hook stop-nudge.sh "$(stop_json false sess-emptycap)"
  assert_reason_has "$COMPACT_MARK"
  [ "$(cat "$CACHE/stop-nudged-turn")" = "9 1" ]
}

@test "a half-written cap file does not silence the nudge via its count column" {
  _seed_usage 60 9
  # 1 列目だけ壊れた状態。2 列目を上限として信じると、回数を減らす経路(新鮮化)へ
  # 到達しないまま恒久的に黙る。
  printf 'broken 3' >"$CACHE/stop-nudged-turn"
  run_hook stop-nudge.sh "$(stop_json false sess-halfcap)"
  assert_reason_has "$COMPACT_MARK"
  [ "$(cat "$CACHE/stop-nudged-turn")" = "9 1" ]
}

@test "no compact nudge when the turn counter is unreadable" {
  _seed_usage 60 9
  _seed_task sess-noturn in_progress
  rm -f "$CACHE/turn"
  run_hook stop-nudge.sh "$(stop_json false sess-noturn)"
  [ "$status" -ne 2 ]
  assert_block
  assert_reason_has "$TASK_MARK"
  assert_reason_lacks "$COMPACT_MARK"
}

@test "no compact nudge when the cap cannot be recorded" {
  _seed_usage 60 9
  _seed_task sess-ro in_progress
  # 書込先をディレクトリにして記録を失敗させる(dir の mode を落としても
  # claude_ctx_cache_ensure が 0700 へ戻すため、権限では再現できない)。
  mkdir -p "$CACHE/stop-nudged-turn"
  run_hook stop-nudge.sh "$(stop_json false sess-ro)"
  [ "$status" -ne 2 ]
  assert_block
  assert_reason_has "$TASK_MARK"
  assert_reason_lacks "$COMPACT_MARK"
}

# --- lib 破損時に既存の安全網を巻き込まないこと ---

@test "a corrupt context-paths.sh drops only the compact nudge, not the task nudge" {
  _seed_task sess-corrupt in_progress
  _seed_usage 60 9
  printf 'if broken syntax (\n' >"$HOME/.claude/hooks/lib/context-paths.sh"
  run_hook stop-nudge.sh "$(stop_json false sess-corrupt)"
  [ "$status" -ne 2 ]
  assert_block
  assert_reason_has "$TASK_MARK"
  assert_reason_lacks "$COMPACT_MARK"
}
