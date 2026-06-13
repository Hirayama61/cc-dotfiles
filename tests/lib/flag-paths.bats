#!/usr/bin/env bats
# flag-paths.sh のキー導出規約を固定する characterization テスト。
# 現行の lossy な挙動(/tmp 固定・'/'→'-' 不可逆・キー衝突)も「現状仕様」として
# 意図的に固定する。#49 修正(PR-4)でこれらを新仕様へ意図的に書き換え、変更を証跡化する。

load ../helpers/common

setup() {
  install_hooks
  FLAG="$HOME/.claude/hooks/lib/flag-paths.sh"
}

@test "flag dir is /tmp/claude-sessions (current; migrated in #49/PR-4)" {
  run "$FLAG" dir
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/claude-sessions" ]
}

@test "review-passed key for a plain branch" {
  run "$FLAG" review-passed myrepo main
  [ "$output" = "/tmp/claude-sessions/review-passed-myrepo--main" ]
}

@test "branch slash collapses to dash (current lossy behavior)" {
  run "$FLAG" review-passed myrepo feature/a-b
  [ "$output" = "/tmp/claude-sessions/review-passed-myrepo--feature-a-b" ]
}

@test "COLLISION (B-1 bug; fixed in PR-4): feature/a-b and feature-a/b map to same key" {
  run "$FLAG" review-passed myrepo feature/a-b
  k1="$output"
  run "$FLAG" review-passed myrepo feature-a/b
  [ "$output" = "$k1" ]
}

@test "empty branch yields trailing double-dash" {
  run "$FLAG" review-passed myrepo ""
  [ "$output" = "/tmp/claude-sessions/review-passed-myrepo--" ]
}

@test "design-reviewed key uses same convention" {
  run "$FLAG" design-reviewed myrepo main
  [ "$output" = "/tmp/claude-sessions/design-reviewed-myrepo--main" ]
}

@test "cs-injected key joins ctx and scope" {
  run "$FLAG" cs-injected ctx123 scopeA
  [ "$output" = "/tmp/claude-sessions/cs-injected-ctx123--scopeA" ]
}
