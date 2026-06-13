#!/usr/bin/env bats
# block-protected-branch-push.sh の E2E。一時 git repo の現在ブランチで判定する。

load ../helpers/common

setup() {
  install_hooks
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" -c user.email=t@t -c user.name=t commit --allow-empty -qm init
}

@test "blocks push while on protected branch main" {
  run_hook block-protected-branch-push.sh \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push\"},\"cwd\":\"$REPO\"}"
  [ "$status" -eq 2 ]
}

@test "blocks merge while on protected branch main" {
  run_hook block-protected-branch-push.sh \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git merge feature\"},\"cwd\":\"$REPO\"}"
  [ "$status" -eq 2 ]
}

@test "allows push while on a feature branch" {
  git -C "$REPO" checkout -q -b feature/x
  run_hook block-protected-branch-push.sh \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push\"},\"cwd\":\"$REPO\"}"
  [ "$status" -eq 0 ]
}

@test "allows non-push/merge commands on protected branch" {
  run_hook block-protected-branch-push.sh \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"},\"cwd\":\"$REPO\"}"
  [ "$status" -eq 0 ]
}

@test "fails open outside a git repo" {
  # BATS_TEST_TMPDIR が万一 git 管理下だと「feature ブランチだから exit 0」で偽の
  # green になる。非 git であることを前提として固定してから fail-open を検証する。
  outside="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$outside"
  run git -C "$outside" rev-parse --is-inside-work-tree
  [ "$status" -ne 0 ]
  run_hook block-protected-branch-push.sh \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push\"},\"cwd\":\"$outside\"}"
  [ "$status" -eq 0 ]
}
