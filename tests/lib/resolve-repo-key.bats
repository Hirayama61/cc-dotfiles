#!/usr/bin/env bats
# resolve-repo-key.sh の論理 repo キー導出を固定する characterization テスト。

load ../helpers/common

setup() {
  install_hooks
  # shellcheck source=/dev/null
  source "$HOME/.claude/hooks/lib/resolve-repo-key.sh"
}

@test "repo key is the repo dir basename for a git dir" {
  r="$BATS_TEST_TMPDIR/myproj"
  mkdir -p "$r"
  git -C "$r" init -q
  run resolve_repo_key "$r"
  [ "$status" -eq 0 ]
  [ "$output" = "myproj" ]
}

@test "repo key for a file uses its dir's repo" {
  r="$BATS_TEST_TMPDIR/myproj2"
  mkdir -p "$r"
  git -C "$r" init -q
  touch "$r/some-file.txt"
  run resolve_repo_key "$r/some-file.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "myproj2" ]
}

@test "repo key is empty outside any git repo / ghq layout" {
  d="$BATS_TEST_TMPDIR/plain"
  mkdir -p "$d"
  run resolve_repo_key "$d"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "repo key normalizes (no normalization needed for plain ascii name)" {
  r="$BATS_TEST_TMPDIR/cc-dotfiles"
  mkdir -p "$r"
  git -C "$r" init -q
  run resolve_repo_key "$r"
  [ "$status" -eq 0 ]
  [ "$output" = "cc-dotfiles" ]
}
