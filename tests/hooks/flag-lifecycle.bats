#!/usr/bin/env bats
# push ゲートフラグの 1 周(#49 移行後): 書込(dir-ensure + review-passed フラグ)→
# 読取(pre-push-selfreview-gate が通す)→ 無効化(postcommit-invalidate-review が消す)→
# 再ブロック。新 state dir(XDG 配下)と SHA サフィックス込みのキーで読取/書込が一致することを担保する。

load ../helpers/common

setup() {
  install_hooks
  FLAG="$HOME/.claude/hooks/lib/flag-paths.sh"
  unset XDG_STATE_HOME

  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name t
  git -C "$REPO" checkout -q -b feature/lifecycle
  ( cd "$REPO" && : >f.txt && git add f.txt && git -c core.hooksPath=/dev/null commit -qm init )
  REPO_KEY="$("$HOME/.claude/hooks/lib/resolve-repo-key.sh" "$REPO")"
}

write_review_flag() {
  "$FLAG" dir-ensure
  touch "$("$FLAG" review-passed "$REPO_KEY" feature/lifecycle)"
}

@test "lifecycle: unreviewed push blocked -> flag passes -> commit invalidates -> blocked again" {
  local push='{"tool_name":"Bash","tool_input":{"command":"git push"},"cwd":"'"$REPO"'"}'
  local commit='{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"cwd":"'"$REPO"'"}'

  # 1) フラグ無し → push ゲートはブロック
  run_hook pre-push-selfreview-gate.sh "$push"
  [ "$status" -eq 2 ]

  # 2) review-passed フラグを書く → 通過(読取と書込が同一キーを得る)
  write_review_flag
  run_hook pre-push-selfreview-gate.sh "$push"
  [ "$status" -eq 0 ]

  # 3) commit で無効化(postcommit が同一キーのフラグを rm)
  run_hook postcommit-invalidate-review.sh "$commit"

  # 4) 再びブロック
  run_hook pre-push-selfreview-gate.sh "$push"
  [ "$status" -eq 2 ]
}
