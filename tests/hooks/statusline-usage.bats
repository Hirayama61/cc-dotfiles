#!/usr/bin/env bats
# statusline-command.py の usage.json 書き出し契約。
# usage.json は context-pressure 系 hook 全体の唯一の使用率供給源(linchpin)なので
# subprocess で固定する: 書込スキーマ / null pct では書かない / transcript_path 欠落 /
# 破損入力でも描画継続 / 0700 dir。

load ../helpers/common

setup() {
  install_hooks
  PY="$REPO_ROOT/home/dot_claude/private_executable_statusline-command.py"
  TP="/Users/x/.claude/projects/-p/sl-ctx.jsonl"
}

sl_input() {
  # $1 = used_percentage の JSON 値(数値 or null)
  printf '{"transcript_path":"%s","model":{"display_name":"M"},"cwd":"%s","context_window":{"used_percentage":%s}}' \
    "$TP" "$BATS_TEST_TMPDIR" "$1"
}

@test "writes usage.json with pct, transcript_path, updated_at" {
  printf '%s' "$(sl_input 42.5)" | python3 "$PY" > /dev/null
  f="$HOME/.cache/claude-context/sl-ctx/usage.json"
  [ -f "$f" ]
  jq -e ".pct == 42.5 and .transcript_path == \"$TP\" and (.updated_at | type == \"number\")" "$f" >/dev/null
}

@test "null used_percentage: does not write usage.json" {
  printf '%s' "$(sl_input null)" | python3 "$PY" > /dev/null
  [ ! -e "$HOME/.cache/claude-context/sl-ctx/usage.json" ]
}

@test "missing transcript_path: does not write, still renders" {
  out="$(printf '{"model":{"display_name":"M"},"context_window":{"used_percentage":10}}' | python3 "$PY")"
  [ -n "$out" ]
  [ ! -d "$HOME/.cache/claude-context" ] || [ -z "$(ls "$HOME/.cache/claude-context" 2>/dev/null)" ]
}

@test "ctx dir created with 0700" {
  printf '%s' "$(sl_input 10)" | python3 "$PY" > /dev/null
  perms="$(stat -f '%Lp' "$HOME/.cache/claude-context/sl-ctx")"
  [ "$perms" = "700" ]
}

@test "broken json input: renders parse error without crash" {
  out="$(printf 'not json' | python3 "$PY")"
  [ "$out" = "parse error" ]
}

@test "unwritable cache: rendering still succeeds" {
  mkdir -p "$HOME/.cache/claude-context"
  chmod 500 "$HOME/.cache/claude-context"
  out="$(printf '%s' "$(sl_input 10)" | python3 "$PY")"
  chmod 700 "$HOME/.cache/claude-context"
  [ -n "$out" ]
}
