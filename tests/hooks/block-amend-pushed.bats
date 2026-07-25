#!/usr/bin/env bats
# block-amend-pushed.sh の E2E。push 済 HEAD の amend だけを止め、未 push の amend と
# 通常 commit は通すことを固定する。判定対象 dir が hook の cwd ではなくコマンドの実対象
# (git -C / cd の畳み込み)であることも合わせて固定する。
#
# push 済の再現には remote-tracking ref を直接作る(`git branch -r --contains HEAD` が
# 非空になれば実装の判定条件を満たすため、実 push もリモートも不要)。
# 遮断は exit 2 のみ。fail-open の判定は「exit != 2」(このリポの規約)。

load ../helpers/common

setup() {
  install_hooks
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" -c user.email=t@t -c user.name=t commit --allow-empty -qm init
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD
}

# 未 push のコミットを1つ積む(HEAD が origin/main に含まれなくなる)。
add_local_commit() {
  git -C "${1:?}" -c user.email=t@t -c user.name=t commit --allow-empty -qm local
}

@test "blocks amend of a pushed HEAD" {
  run_hook block-amend-pushed.sh \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit --amend --no-edit\"},\"cwd\":\"$REPO\"}"
  [ "$status" -eq 2 ]
}

@test "blocks a quoted --amend flag" {
  run_hook block-amend-pushed.sh \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit \\\"--amend\\\" --no-edit\"},\"cwd\":\"$REPO\"}"
  [ "$status" -eq 2 ]
}

@test "blocks amend targeted by git -C from a non-repo cwd" {
  outside="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$outside"
  run_hook block-amend-pushed.sh \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO commit --amend --no-edit\"},\"cwd\":\"$outside\"}"
  [ "$status" -eq 2 ]
}

@test "blocks amend after cd into the pushed repo" {
  outside="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$outside"
  run_hook block-amend-pushed.sh \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $REPO && git commit --amend --no-edit\"},\"cwd\":\"$outside\"}"
  [ "$status" -eq 2 ]
}

@test "allows amend of an unpushed commit" {
  add_local_commit "$REPO"
  run_hook block-amend-pushed.sh \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit --amend --no-edit\"},\"cwd\":\"$REPO\"}"
  [ "$status" -eq 0 ]
}

@test "allows a normal commit on a pushed HEAD" {
  run_hook block-amend-pushed.sh \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"cwd\":\"$REPO\"}"
  [ "$status" -eq 0 ]
}

@test "per-segment target: amend in another unpushed repo is allowed" {
  # cwd が push 済 repo でも、git -C が指す先が未 push なら止めない(F-002 の per-amend 解決)。
  other="$BATS_TEST_TMPDIR/other"
  mkdir -p "$other"
  git -C "$other" init -q -b main
  add_local_commit "$other"
  run_hook block-amend-pushed.sh \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $other commit --amend --no-edit\"},\"cwd\":\"$REPO\"}"
  [ "$status" -eq 0 ]
}

@test "allows amend in a repo without any commit (unborn HEAD)" {
  unborn="$BATS_TEST_TMPDIR/unborn"
  mkdir -p "$unborn"
  git -C "$unborn" init -q -b main
  run_hook block-amend-pushed.sh \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit --amend --no-edit\"},\"cwd\":\"$unborn\"}"
  [ "$status" -eq 0 ]
}

@test "fails open outside a git repo (exit != 2)" {
  outside="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$outside"
  run git -C "$outside" rev-parse --is-inside-work-tree
  [ "$status" -ne 0 ]
  run_hook block-amend-pushed.sh \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit --amend --no-edit\"},\"cwd\":\"$outside\"}"
  [ "$status" -ne 2 ]
}

@test "guarded source: corrupt resolve-git-target lib fails open (exit != 2)" {
  echo "{ broken bash (" >"$HOME/.claude/hooks/lib/resolve-git-target.sh"
  run_hook block-amend-pushed.sh \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit --amend --no-edit\"},\"cwd\":\"$REPO\"}"
  [ "$status" -ne 2 ]
}

@test "fails open without jq (exit != 2)" {
  local nojq
  nojq="$(make_no_jq_path)"
  run_hook_env "$nojq" block-amend-pushed.sh \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit --amend --no-edit\"},\"cwd\":\"$REPO\"}"
  [ "$status" -ne 2 ]
}
