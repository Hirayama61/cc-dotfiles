#!/usr/bin/env bats
# block-no-verify.sh の E2E。lib 取り込みの fail-open(A-1 修正後)を固定する。
# かつて resolve-git-target.sh を bare source していたため破損 lib で set -e 下に
# exit 2(=ブロック)へ化けた。PR-3 で source_hook_lib 化し、破損 lib でも exit 0
# (fail-open)になることを下の "bare source fixed" テストで固定する。

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

@test "bare source fixed (A-1): corrupt resolve-git-target lib fails open (exit 0)" {
  echo "{ broken bash (" >"$HOME/.claude/hooks/lib/resolve-git-target.sh"
  run_hook block-no-verify.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'
  [ "$status" -eq 0 ]
}
