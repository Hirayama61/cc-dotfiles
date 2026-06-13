#!/usr/bin/env bats
# block-no-verify.sh の E2E。bare source(ガード無し直 source)の現状を固定する。
# A-1: 破損 lib を bare source すると set -e 下で hook が exit 2(=ブロック)に化ける。
# これは fail-CLOSED 違反で、PR-3 で source_hook_lib 化して exit 0(fail-open)へ修正し、
# 下の "current behavior" テストを green(exit 0 期待)へ書き換えて変更を証跡化する。

load ../helpers/common

setup() {
  install_hooks
}

@test "blocks git commit --no-verify" {
  run_hook block-no-verify.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify -m x"}}'
  [ "$status" -eq 2 ]
}

@test "blocks git commit -n (bundled short flag)" {
  run_hook block-no-verify.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git commit -nm x"}}'
  [ "$status" -eq 2 ]
}

@test "allows a normal commit" {
  run_hook block-no-verify.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'
  [ "$status" -eq 0 ]
}

@test "no false positive: 'bash -n' before commit is not treated as no-verify" {
  run_hook block-no-verify.sh \
    '{"tool_name":"Bash","tool_input":{"command":"bash -n script.sh && git commit -m x"}}'
  [ "$status" -eq 0 ]
}

@test "BARE SOURCE current behavior (A-1; PR-3 -> exit 0): corrupt lib makes hook exit 2" {
  echo "{ broken bash (" >"$HOME/.claude/hooks/lib/resolve-git-target.sh"
  run_hook block-no-verify.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'
  [ "$status" -eq 2 ]
}
