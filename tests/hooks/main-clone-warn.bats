#!/usr/bin/env bats
# main-clone-warn.sh の characterization。
# SessionStart で cwd が main clone(~/ghq/ のプライマリ作業ツリー)の時だけ
# additionalContext 警告を注入し、linked worktree / 非 ghq / 非 git は無音を固定する。

load ../helpers/common

setup() {
  install_hooks
  MAIN="$HOME/ghq/github.com/o/r"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q
  git -C "$MAIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
}

session_json() {
  printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$1"
}

@test "main clone cwd: injects warning with worktree guidance" {
  run_hook main-clone-warn.sh "$(session_json "$MAIN")"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'main-clone-warn'
  echo "$output" | grep -qF 'wt.sh'
  echo "$output" | grep -qF '"hookEventName": "SessionStart"'
}

@test "linked worktree cwd: silent" {
  git -C "$MAIN" worktree add -q "$HOME/worktrees/r-feat" -b feat/x
  run_hook main-clone-warn.sh "$(session_json "$HOME/worktrees/r-feat")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "non-ghq git repo cwd: silent" {
  OTHER="$HOME/repos/other"
  mkdir -p "$OTHER"
  git -C "$OTHER" init -q
  run_hook main-clone-warn.sh "$(session_json "$OTHER")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "non-git dir under ghq: silent" {
  PLAIN="$HOME/ghq/github.com/o/plain"
  mkdir -p "$PLAIN"
  run_hook main-clone-warn.sh "$(session_json "$PLAIN")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "empty cwd: silent fail-open" {
  run_hook main-clone-warn.sh '{"hook_event_name":"SessionStart"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "relative cwd: silent fail-open" {
  run_hook main-clone-warn.sh '{"hook_event_name":"SessionStart","cwd":"ghq/github.com/o/r"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
