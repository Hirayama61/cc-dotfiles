#!/usr/bin/env bats
# block-test-deletion.sh の E2E。guarded source(lib 破損で fail-open)の正しい例。
# D-M1 の偽陽性(独立 2-grep)も「現状バグ」として固定し PR-3 で修正(red→green)する。

load ../helpers/common

setup() {
  install_hooks
}

@test "blocks rm of a test file (Bash)" {
  run_hook block-test-deletion.sh \
    '{"tool_name":"Bash","tool_input":{"command":"rm foo.test.js"}}'
  [ "$status" -eq 2 ]
}

@test "allows rm of a non-test file (Bash)" {
  run_hook block-test-deletion.sh \
    '{"tool_name":"Bash","tool_input":{"command":"rm README.md"}}'
  [ "$status" -eq 0 ]
}

@test "guarded source: corrupt test-patterns lib fails open (exit 0)" {
  echo "this is { not ) valid bash (" >"$HOME/.claude/hooks/lib/test-patterns.sh"
  run_hook block-test-deletion.sh \
    '{"tool_name":"Bash","tool_input":{"command":"rm foo.test.js"}}'
  [ "$status" -eq 0 ]
}

@test "FP (D-M1 bug; fixed in PR-3): rm non-test + cp test file is wrongly blocked" {
  # 独立した 2 つの grep(rm 系の存在 / テストパス名の存在)を AND 判定するため、
  # 削除対象は build/ なのにコマンド中に test ファイル名が出るだけで誤ブロックする。
  run_hook block-test-deletion.sh \
    '{"tool_name":"Bash","tool_input":{"command":"rm -rf build/ && cp src/foo.test.js dist/"}}'
  [ "$status" -eq 2 ]
}

@test "blocks deletion of assertions via Edit on a test file" {
  run_hook block-test-deletion.sh \
    '{"tool_name":"Edit","tool_input":{"file_path":"a.test.js","old_string":"expect(x).toBe(1)","new_string":""}}'
  [ "$status" -eq 2 ]
}
