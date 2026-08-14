#!/usr/bin/env bats
# context-paths.sh の契約。cache パス導出・ctx sanitize・ensure の検証と、
# statusline(python)側 ctx_key との二言語等価性を固定する(不一致は usage.json の
# 読み書きパスがズレて全系が無音 fail-open になるため、キーの完全一致が生命線)。

load ../helpers/common

setup() {
  install_hooks
  LIB="$HOME/.claude/hooks/lib/context-paths.sh"
  PY="$REPO_ROOT/home/dot_claude/private_executable_statusline-command.py"
}

@test "key: derives ctx from transcript_path" {
  run bash "$LIB" key "/Users/x/.claude/projects/-p/abc-123.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "abc-123" ]
}

@test "key: empty input yields empty" {
  run bash "$LIB" key ""
  [ "$output" = "" ]
}

@test "key: dot and dotdot rejected" {
  run bash "$LIB" key "."
  [ "$output" = "" ]
  run bash "$LIB" key ".."
  [ "$output" = "" ]
  run bash "$LIB" key ".jsonl"
  [ "$output" = "" ]
}

@test "dir: under XDG_CACHE_HOME when absolute" {
  XDG_CACHE_HOME="$BATS_TEST_TMPDIR/xdg" run bash "$LIB" dir ctx1
  [ "$output" = "$BATS_TEST_TMPDIR/xdg/claude-context/ctx1" ]
}

@test "dir: relative XDG_CACHE_HOME falls back to HOME cache" {
  XDG_CACHE_HOME="rel/path" run bash "$LIB" dir ctx1
  [ "$output" = "$HOME/.cache/claude-context/ctx1" ]
}

@test "ensure: creates 0700 dir" {
  run bash "$LIB" ensure ctx1
  [ "$status" -eq 0 ]
  dir="$HOME/.cache/claude-context/ctx1"
  [ -d "$dir" ]
  perms="$(stat -f '%Lp' "$dir")"
  [ "$perms" = "700" ]
}

@test "ensure: empty ctx fails" {
  run bash "$LIB" ensure ""
  [ "$status" -ne 0 ]
}

@test "dir and accessors reject traversal ctx" {
  # dispatcher は SKILL からの直接実行に公開されるため accessor 側でも segment を再検証する
  for sub in dir usage state decisions turn stamp; do
    run bash "$LIB" "$sub" "../x"
    if [ "$status" -eq 0 ] && [ -n "$output" ] && [ "$output" != "/" ]; then
      case "$output" in
      *"claude-context/../"*) echo "traversal leaked: $sub -> $output"; return 1 ;;
      esac
      echo "unexpected success: $sub -> $output"; return 1
    fi
  done
}

@test "file path accessors are under ctx dir" {
  for sub in usage state decisions turn stamp; do
    run bash "$LIB" "$sub" ctx1
    case "$output" in
    "$HOME/.cache/claude-context/ctx1/"*) ;;
    *) echo "unexpected: $sub -> $output"; return 1 ;;
    esac
  done
}

# 二言語契約: bash claude_ctx_key と python ctx_key に同一バッテリを食わせ完全一致を検証
@test "cross-language contract: bash and python derive identical ctx keys" {
  # 末尾スラッシュ入りは bash basename と python os.path.basename の挙動が割れるが、
  # transcript_path は常に .jsonl ファイルパスなので契約の対象外とする。
  battery=(
    "/Users/x/.claude/projects/-p/abc-123.jsonl"
    "/Users/x/.claude/projects/-p/no-ext"
    "abc.jsonl"
    ""
    "."
    ".."
  )
  for input in "${battery[@]}"; do
    b="$(bash "$LIB" key "$input")"
    p="$(python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('sl', '$PY')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
sys.stdout.write(m.ctx_key(sys.argv[1]))
" "$input")"
    if [ "$b" != "$p" ]; then
      echo "mismatch for '$input': bash='$b' python='$p'"
      return 1
    fi
  done
}

# --- state-stamp の行書式と鮮度判定 ---
# 判定は precompact-gate と stop-nudge が共有する唯一の定義点なので、真理値表で固定する。

FRESH_CTX="ctx-fresh"

# 鮮度判定の材料を置く($1 = 現在 turn、$2 = stamp 行、$3 = 現在 pct)。
# $2 に none を渡すと stamp ファイル自体を作らない。
seed_freshness() {
  local dir="$HOME/.cache/claude-context/$FRESH_CTX"
  mkdir -p "$dir"
  chmod 700 "$dir"
  printf 'x\n' > "$dir/state.md"
  printf '%s' "$1" > "$dir/turn"
  if [ "$2" != "none" ]; then
    printf '%s' "$2" > "$dir/state-stamp"
  else
    rm -f "$dir/state-stamp"
  fi
  printf '{"pct":%s,"updated_at":%s}' "${3:-40}" "$(date +%s)" > "$dir/usage.json"
}

is_fresh() {
  bash -c '. "$1"; claude_ctx_state_is_fresh "$2"' _ "$LIB" "$FRESH_CTX"
}

stamp_line() {
  bash -c '. "$1"; claude_ctx_state_stamp_line "$2" "$3"' _ "$LIB" "$1" "$2"
}

stamp_field() {
  bash -c '. "$1"; claude_ctx_state_stamp_field "$2" "$3"' _ "$LIB" "$FRESH_CTX" "$1"
}

@test "stamp line: numeric pct is kept, unusable pct becomes a dash" {
  [ "$(stamp_line 5 40)" = "5 40" ]
  [ "$(stamp_line 5 '')" = "5 -" ]
  [ "$(stamp_line 5 'abc')" = "5 -" ]
}

@test "stamp field: round trips turn and pct, and reads a dash as unknown" {
  seed_freshness 6 '5 40'
  [ "$(stamp_field 1)" = "5" ]
  [ "$(stamp_field 2)" = "40" ]
  seed_freshness 6 '5 -'
  [ "$(stamp_field 1)" = "5" ]
  [ "$(stamp_field 2)" = "" ]
}

@test "fresh: turn difference inside the allowance" {
  seed_freshness 5 '5 40'
  is_fresh
  seed_freshness 7 '5 40'
  is_fresh
}

@test "stale: turn difference at or beyond the allowance" {
  seed_freshness 8 '5 40'
  run is_fresh
  [ "$status" -ne 0 ]
}

@test "stale: turn moved backwards" {
  seed_freshness 2 '5 40'
  run is_fresh
  [ "$status" -ne 0 ]
}

@test "stale: usage grew past the allowance within the turn allowance" {
  seed_freshness 6 '5 30' 40
  run is_fresh
  [ "$status" -ne 0 ]
}

@test "fresh: usage grew but stayed inside the allowance" {
  seed_freshness 6 '5 30' 39
  is_fresh
}

@test "fresh: usage dropped after a compaction" {
  seed_freshness 6 '5 60' 10
  is_fresh
}

@test "fresh: unknown pct in the stamp falls back to the turn dimension" {
  seed_freshness 6 '5 -' 99
  is_fresh
}

@test "fresh: a stale usage.json falls back to the turn dimension" {
  seed_freshness 6 '5 30' 99
  printf '{"pct":99,"updated_at":1}' > "$HOME/.cache/claude-context/$FRESH_CTX/usage.json"
  is_fresh
}

@test "fresh: unreadable usage.json falls back to the turn dimension" {
  seed_freshness 6 '5 30' 99
  rm -f "$HOME/.cache/claude-context/$FRESH_CTX/usage.json"
  is_fresh
}

@test "stale: no stamp at all" {
  seed_freshness 6 none
  run is_fresh
  [ "$status" -ne 0 ]
}

@test "stale: non-numeric turn in the stamp" {
  seed_freshness 6 'abc 40'
  run is_fresh
  [ "$status" -ne 0 ]
}

@test "stale: no state file even with a fresh stamp" {
  seed_freshness 6 '5 40'
  rm -f "$HOME/.cache/claude-context/$FRESH_CTX/state.md"
  run is_fresh
  [ "$status" -ne 0 ]
}

@test "stale: unreadable turn counter" {
  seed_freshness 6 '5 40'
  rm -f "$HOME/.cache/claude-context/$FRESH_CTX/turn"
  run is_fresh
  [ "$status" -ne 0 ]
}
