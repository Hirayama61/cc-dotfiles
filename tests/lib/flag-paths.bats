#!/usr/bin/env bats
# flag-paths.sh のキー導出規約と state dir 提供を固定する(#49 で新仕様へ移行)。
# 旧 characterization(/tmp 固定・'/'→'-' 不可逆・キー衝突の意図的固定)を新仕様へ
# 書き換え、変更を証跡化する: XDG 配下 state dir / dir-ensure の 0700 検証 /
# SHA サフィックスによる feature/a-b ≠ feature-a/b。

load ../helpers/common

setup() {
  install_hooks
  FLAG="$HOME/.claude/hooks/lib/flag-paths.sh"
  # 既定は XDG_STATE_HOME 不設定 = $HOME/.local/state(install_hooks の一時 HOME 配下)。
  unset XDG_STATE_HOME
}

@test "flag dir defaults to \$HOME/.local/state/claude-sessions when XDG unset" {
  run "$FLAG" dir
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.local/state/claude-sessions" ]
}

@test "flag dir honors an absolute XDG_STATE_HOME" {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/xdg"
  run "$FLAG" dir
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/xdg/claude-sessions" ]
}

@test "flag dir ignores a relative XDG_STATE_HOME (falls back to HOME)" {
  export XDG_STATE_HOME="relative/state"
  run "$FLAG" dir
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.local/state/claude-sessions" ]
}

@test "review-passed key for a plain branch carries a SHA suffix" {
  local dir hash
  dir="$HOME/.local/state/claude-sessions"
  hash="$(printf '%s' main | shasum -a 256 | cut -c1-8)"
  run "$FLAG" review-passed myrepo main
  [ "$status" -eq 0 ]
  [ "$output" = "$dir/review-passed-myrepo--main-$hash" ]
}

@test "branch slash is sanitized to dash but suffix keeps it unique" {
  local dir hash
  dir="$HOME/.local/state/claude-sessions"
  hash="$(printf '%s' feature/a-b | shasum -a 256 | cut -c1-8)"
  run "$FLAG" review-passed myrepo feature/a-b
  [ "$status" -eq 0 ]
  [ "$output" = "$dir/review-passed-myrepo--feature-a-b-$hash" ]
}

@test "FIXED (B-1): feature/a-b and feature-a/b map to DIFFERENT keys" {
  run "$FLAG" review-passed myrepo feature/a-b
  local k1="$output"
  run "$FLAG" review-passed myrepo feature-a/b
  [ "$status" -eq 0 ]
  [ "$output" != "$k1" ]
}

@test "same branch yields the same key (reader/writer roundtrip)" {
  run "$FLAG" review-passed myrepo feature/x
  local k1="$output"
  run "$FLAG" review-passed myrepo feature/x
  [ "$output" = "$k1" ]
}

@test "empty branch yields trailing double-dash with no suffix" {
  local dir
  dir="$HOME/.local/state/claude-sessions"
  run "$FLAG" review-passed myrepo ""
  [ "$status" -eq 0 ]
  [ "$output" = "$dir/review-passed-myrepo--" ]
}

@test "design-reviewed key uses the same branch convention" {
  local hash
  hash="$(printf '%s' main | shasum -a 256 | cut -c1-8)"
  run "$FLAG" design-reviewed myrepo main
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.local/state/claude-sessions/design-reviewed-myrepo--main-$hash" ]
}

@test "cs-injected joins ctx and scope (no branch suffix)" {
  run "$FLAG" cs-injected ctx123 scopeA
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.local/state/claude-sessions/cs-injected-ctx123--scopeA" ]
}

@test "dir-ensure creates the state dir with mode 0700" {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/xdg"
  run "$FLAG" dir-ensure
  [ "$status" -eq 0 ]
  local d="$BATS_TEST_TMPDIR/xdg/claude-sessions"
  [ -d "$d" ]
  [ "$(stat -f '%Lp' "$d")" = "700" ]
}

@test "dir-ensure tightens a pre-existing loose dir to 0700" {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$BATS_TEST_TMPDIR/xdg/claude-sessions"
  chmod 755 "$BATS_TEST_TMPDIR/xdg/claude-sessions"
  run "$FLAG" dir-ensure
  [ "$status" -eq 0 ]
  [ "$(stat -f '%Lp' "$BATS_TEST_TMPDIR/xdg/claude-sessions")" = "700" ]
}

@test "dir-ensure rejects a symlinked state dir (non-zero)" {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$BATS_TEST_TMPDIR/realdir" "$BATS_TEST_TMPDIR/xdg"
  ln -s "$BATS_TEST_TMPDIR/realdir" "$BATS_TEST_TMPDIR/xdg/claude-sessions"
  run "$FLAG" dir-ensure
  [ "$status" -ne 0 ]
}
