#!/usr/bin/env bats
# push ゲートフラグの 1 周を writer(self-review skill)→ reader(gate)で通しで固定する。
# フラグは head 行で HEAD に束縛されるため、書式が writer / reader のどちらかでずれると
# 恒久ブロック or 静かな承認になる。テスト側で head 行を手書きするとそのずれを検出できないので、
# フラグ作成は必ず実 writer(create-review-flag.sh)に行わせる。
# 併せて、HEAD 束縛だけで無効化されること(postcommit を走らせないケース)と、
# 旧形式フラグ / 版ずれ lib の向きを個別に固定する。

load ../helpers/common

setup() {
  install_hooks
  FLAG="$HOME/.claude/hooks/lib/flag-paths.sh"
  CREATE="$REPO_ROOT/home/dot_claude/skills/self-review/scripts/executable_create-review-flag.sh"
  unset XDG_STATE_HOME

  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name t
  git -C "$REPO" checkout -q -b feature/lifecycle
  ( cd "$REPO" && : >f.txt && git add f.txt && git -c core.hooksPath=/dev/null commit -qm init )
  REPO_KEY="$("$HOME/.claude/hooks/lib/resolve-repo-key.sh" "$REPO")"
  FLAG_FILE="$("$FLAG" review-passed "$REPO_KEY" feature/lifecycle)"

  PUSH='{"tool_name":"Bash","tool_input":{"command":"git push"},"cwd":"'"$REPO"'"}'
  COMMIT='{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"cwd":"'"$REPO"'"}'
}

# 実 writer で review-passed フラグを作る(指摘ゼロ・Tier OK の正経路)。
run_writer() {
  ( cd "$REPO" && printf '' | bash "$CREATE" \
      "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" '' '' )
}

# 対象 repo に新しいコミットを積んで HEAD を動かす。
# グローバル pre-commit(Conventional Commits 検査)に止められないよう hooksPath を無効化する。
new_commit() {
  ( cd "$REPO" && printf 'x\n' >> f.txt && git add f.txt \
      && git -c core.hooksPath=/dev/null commit -qm more )
}

@test "lifecycle: writer flag passes, new commit invalidates via HEAD, postcommit clears, writer again passes" {
  # 1) フラグ無し → ブロック
  run_hook pre-push-selfreview-gate.sh "$PUSH"
  [ "$status" -eq 2 ]

  # 2) 実 writer が書いたフラグで通過(writer と gate が同じ書式を得ている)
  run_writer
  run_hook pre-push-selfreview-gate.sh "$PUSH"
  [ "$status" -eq 0 ]

  # 3) 新規コミットで HEAD が動く → postcommit を走らせなくても不一致でブロック
  new_commit
  run_hook pre-push-selfreview-gate.sh "$PUSH"
  [ "$status" -eq 2 ]

  # 4) postcommit がフラグを消す(HEAD 束縛とは独立した二重の無効化)
  run_hook postcommit-invalidate-review.sh "$COMMIT"
  [ ! -e "$FLAG_FILE" ]

  # 5) 再レビュー相当で writer を回すと現 HEAD のフラグができ、また通る
  run_writer
  run_hook pre-push-selfreview-gate.sh "$PUSH"
  [ "$status" -eq 0 ]
}

@test "head match alone passes: postcommit never runs" {
  run_writer
  run_hook pre-push-selfreview-gate.sh "$PUSH"
  [ "$status" -eq 0 ]
  [ -f "$FLAG_FILE" ]
}

@test "head mismatch alone blocks: postcommit never runs" {
  run_writer
  new_commit
  run_hook pre-push-selfreview-gate.sh "$PUSH"
  [ "$status" -eq 2 ]
  # フラグは消えていない(ブロックは HEAD 束縛だけで成立している)
  [ -f "$FLAG_FILE" ]
  printf '%s' "$output" | grep -qF "不一致"
}

@test "legacy flag without a head line is refused" {
  "$FLAG" dir-ensure
  printf 'tier1-ack: 旧形式\n' > "$FLAG_FILE"
  run_hook pre-push-selfreview-gate.sh "$PUSH"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qF "head 行が無い"
}

@test "stale lib without the head helper fails open (never exit 2)" {
  # 版ずれ(hook は新・lib は旧)の模擬。source 時に新関数が無い状態を作る。
  run_writer
  printf '%s\n' 'unset -f review_flag_head_of' >> "$HOME/.claude/hooks/lib/flag-paths.sh"
  new_commit
  # 本来なら head 不一致でブロックする状況だが、判定材料が無いので素通しへ倒れる。
  run_hook pre-push-selfreview-gate.sh "$PUSH"
  [ "$status" -ne 2 ]
}
