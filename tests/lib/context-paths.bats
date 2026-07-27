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

@test "base: prints cache base without ctx argument" {
  XDG_CACHE_HOME="$BATS_TEST_TMPDIR/xdg" run bash "$LIB" base
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/xdg/claude-context" ]
}

@test "base: relative XDG_CACHE_HOME falls back to HOME cache" {
  XDG_CACHE_HOME="rel/path" run bash "$LIB" base
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.cache/claude-context" ]
}

@test "base: extra argument does not change output" {
  XDG_CACHE_HOME="$BATS_TEST_TMPDIR/xdg" run bash "$LIB" base ../x
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/xdg/claude-context" ]
}

@test "stale-secs: prints the usage.json freshness threshold" {
  run bash "$LIB" stale-secs
  [ "$status" -eq 0 ]
  [ "$output" = "1800" ]
}

@test "compacted: path is under ctx dir" {
  run bash "$LIB" compacted ctx1
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.cache/claude-context/ctx1/compacted" ]
}

@test "usage help lists every subcommand the dispatcher accepts" {
  run bash "$LIB"
  [ "$status" -ne 0 ]
  for sub in key dir ensure usage state decisions turn compacted base stale-secs; do
    case "$output" in
    *"$sub"*) ;;
    *) echo "usage help missing: $sub"; return 1 ;;
    esac
  done
}

@test "dir and accessors reject traversal ctx" {
  # dispatcher は SKILL からの直接実行に公開されるため accessor 側でも segment を再検証する
  for sub in dir usage state decisions turn compacted; do
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
  for sub in usage state decisions turn; do
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
