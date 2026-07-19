#!/usr/bin/env bats
# block-main-clone-edit.sh の characterization。
# 判定核を lib/resolve-main-clone.sh へ集約したリファクタ(2026-07-19)の同一入力突き合わせ:
# main clone のファイル編集は exit 2、linked worktree / 非 ghq / 相対パスは非ブロックを固定する。

load ../helpers/common

setup() {
  install_hooks
  MAIN="$HOME/ghq/github.com/o/r"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q
  git -C "$MAIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
}

edit_json() {
  printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1"
}

@test "edit in main clone: blocked with worktree guidance" {
  run_hook block-main-clone-edit.sh "$(edit_json "$MAIN/file.txt")"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'main clone'
  echo "$output" | grep -qF 'wt.sh'
}

@test "edit in linked worktree: allowed" {
  git -C "$MAIN" worktree add -q "$HOME/worktrees/r-feat" -b feat/x
  run_hook block-main-clone-edit.sh "$(edit_json "$HOME/worktrees/r-feat/file.txt")"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "edit outside ghq: allowed" {
  OTHER="$HOME/repos/other"
  mkdir -p "$OTHER"
  git -C "$OTHER" init -q
  run_hook block-main-clone-edit.sh "$(edit_json "$OTHER/file.txt")"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "relative file_path: allowed fail-open" {
  run_hook block-main-clone-edit.sh '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"ghq/github.com/o/r/file.txt"}}'
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}
