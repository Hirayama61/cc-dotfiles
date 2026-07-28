#!/usr/bin/env bats
# block-destructive-git.sh の E2E。対象サブコマンドごとに「破棄する形は止め、破棄しない
# 隣接形は通す」境界を固定する(reset --hard / clean -f / stash drop・clear /
# branch -D / restore / checkout -- / worktree remove --force)。
#
# 遮断は exit 2 のみ。fail-open の判定は「exit != 2」(このリポの規約)。
# restore / checkout の `--` と `-f` / worktree は隣接する分岐で、status だけでは
# 「別分岐が発火した」型の退行を検知できないため、ブロックメッセージも突き合わせる。

load ../helpers/common

setup() {
  install_hooks
}

@test "blocks git reset --hard" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~1"}}'
  [ "$status" -eq 2 ]
}

@test "allows git reset --soft" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git reset --soft HEAD~1"}}'
  [ "$status" -eq 0 ]
}

@test "allows git reset without --hard (mixed)" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git reset HEAD~1"}}'
  [ "$status" -eq 0 ]
}

@test "blocks git clean -fd" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git clean -fd"}}'
  [ "$status" -eq 2 ]
}

@test "allows git clean -nfd (dry-run wins over -f)" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git clean -nfd"}}'
  [ "$status" -eq 0 ]
}

@test "blocks git clean --force (long flag, no path)" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git clean --force"}}'
  [ "$status" -eq 2 ]
}

@test "allows git clean --dry-run --force" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git clean --dry-run --force"}}'
  [ "$status" -eq 0 ]
}

@test "blocks git stash drop" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git stash drop"}}'
  [ "$status" -eq 2 ]
}

@test "blocks git stash clear" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git stash clear"}}'
  [ "$status" -eq 2 ]
}

@test "allows git stash list" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git stash list"}}'
  [ "$status" -eq 0 ]
}

@test "blocks git branch -D" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git branch -D feature/x"}}'
  [ "$status" -eq 2 ]
}

@test "blocks git branch --delete --force" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git branch --delete --force feature/x"}}'
  [ "$status" -eq 2 ]
}

@test "allows git branch -d (merged-only safe delete)" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git branch -d feature/x"}}'
  [ "$status" -eq 0 ]
}

@test "blocks git restore of a worktree path" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git restore src/main.sh"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'git restore'
}

@test "blocks git restore --staged --worktree" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git restore --staged --worktree src/main.sh"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'git restore'
}

@test "allows git restore --staged (index only)" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git restore --staged src/main.sh"}}'
  [ "$status" -eq 0 ]
}

@test "blocks git checkout -- path" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git checkout -- src/main.sh"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'git checkout -- <path>'
}

@test "blocks git checkout -f" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git checkout -f main"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'git checkout -f'
}

@test "blocks git checkout --force (long flag)" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git checkout --force main"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'git checkout -f'
}

@test "allows git checkout -b (new branch)" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git checkout -b feature/x"}}'
  [ "$status" -eq 0 ]
}

@test "allows a plain branch switch" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git checkout main"}}'
  [ "$status" -eq 0 ]
}

@test "blocks git switch -f" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git switch -f main"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'git switch --discard-changes / -f'
}

@test "blocks git switch --discard-changes" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git switch --discard-changes main"}}'
  [ "$status" -eq 2 ]
}

@test "blocks git switch --force (alias of --discard-changes)" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git switch --force main"}}'
  [ "$status" -eq 2 ]
}

@test "allows git switch -c (new branch)" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git switch -c feature/x"}}'
  [ "$status" -eq 0 ]
}

# ヘッダが「対象外」と宣言した形。allows でなく accepted gap: にしているのは、塞ぐ判断が
# 出た時に落として書き換える前提だから(D-37 が閉じたらこの 2 本は消える)。
# 逆向きの退行を止めるのが目的で、`--force` の判定を前方一致に緩めると --force-create が
# 巻き込まれる。
@test "accepted gap: git switch -C is out of scope (branch ref, not working tree)" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git switch -C main"}}'
  [ "$status" -ne 2 ]
}

@test "accepted gap: git switch --force-create is out of scope" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git switch --force-create main"}}'
  [ "$status" -ne 2 ]
}

# `--` の無い pathspec。ref 名として不正な形(先頭 `.` / `/`、`..`、`*` を含む)だけを
# 見るので、下の allows 群は巻き込まない。
@test "blocks git checkout . (pathspec without --)" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git checkout ."}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'git checkout <path>'
}

@test "blocks git checkout with a relative pathspec" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git checkout ./src"}}'
  [ "$status" -eq 2 ]
}

@test "blocks git checkout with a parent pathspec" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git checkout ../other"}}'
  [ "$status" -eq 2 ]
}

@test "blocks git checkout with an absolute pathspec" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git checkout /tmp/x"}}'
  [ "$status" -eq 2 ]
}

@test "blocks git checkout with a glob pathspec" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git checkout '*.sh'"}}'
  [ "$status" -eq 2 ]
}

@test "allows git checkout of a remote-tracking ref" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git checkout origin/main"}}'
  [ "$status" -eq 0 ]
}

@test "allows git checkout of a tag with dots" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git checkout v1.0.0"}}'
  [ "$status" -eq 0 ]
}

@test "allows git checkout of a revision expression" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git checkout HEAD~1"}}'
  [ "$status" -eq 0 ]
}

# pathspec 判定は `checkout` より後ろだけを見る。前置グローバルオプションの引数を
# 巻き込むと、ただのブランチ切替が止まる。
@test "allows git -C <abs path> checkout of a branch" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo checkout main"}}'
  [ "$status" -eq 0 ]
}

@test "blocks git -C <abs path> checkout . (pathspec still caught)" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo checkout ."}}'
  [ "$status" -eq 2 ]
}

# ref 名として妥当な形は pathspec と区別できない。過剰遮断側へ倒すと
# `git checkout <branch>` が巻き込まれるため、こちらは通す。
@test "accepted gap: git checkout <path> that is also a valid ref name is not blocked" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git checkout src/main.sh"}}'
  [ "$status" -ne 2 ]
}

@test "allows a plain git switch" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git switch main"}}'
  [ "$status" -eq 0 ]
}

@test "blocks git worktree remove --force" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git worktree remove --force /tmp/wt"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'git worktree remove --force'
}

@test "blocks git worktree remove -f (short flag)" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git worktree remove -f /tmp/wt"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'git worktree remove --force'
}

@test "allows git worktree remove without --force" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git worktree remove /tmp/wt"}}'
  [ "$status" -eq 0 ]
}

@test "allows git worktree add" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git worktree add -f /tmp/wt main"}}'
  [ "$status" -eq 0 ]
}

@test "blocks a destructive segment inside a subshell" {
  # split_git_segments が括弧も分割点にするため、癒着した `(cd x && git reset --hard)` も届く。
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"(cd /tmp && git reset --hard)"}}'
  [ "$status" -eq 2 ]
}

@test "no false positive: destructive command inside a string literal is allowed" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"echo \"git reset --hard\" > notes.txt"}}'
  [ "$status" -eq 0 ]
}

@test "no false positive: destructive command inside a heredoc body is allowed" {
  # strip_heredocs が本文を除去する経路。ドキュメントや手順書を heredoc で書き出す時に
  # 本文中の git コマンドで誤爆しないことを固定する。
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"cat <<EOT > notes.txt\ngit reset --hard\nEOT"}}'
  [ "$status" -eq 0 ]
}

@test "blocks a destructive command after a false heredoc start" {
  # D-38: strip_heredocs はクォート内の `<<`+語 も heredoc 開始と誤認するが、終端タグが
  # 来ないまま EOF に達したら捨てた行を出し直す。gh 側と同じ穴がこちらにもあった。
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"echo \"see a << b\"\ngit reset --hard"}}'
  [ "$status" -eq 2 ]
}

@test "falls back to the strict strip_heredocs when the lenient one is missing" {
  # apply 前後の版ずれで lib が旧版になる瞬間を模す。除去ゼロへ後退すると heredoc 本文の
  # コマンド例で誤ブロックするため、厳格版が残っていればそちらへ落ちること。
  sed -i '' 's/^strip_heredocs_lenient()/_gone_strip_heredocs_lenient()/' \
    "$HOME/.claude/hooks/lib/resolve-git-target.sh"
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"cat <<EOT > notes.txt\ngit reset --hard\nEOT"}}'
  [ "$status" -ne 2 ]
}

@test "accepted gap: a heredoc executed as stdin is not inspected" {
  # `bash <<EOF` の本文は実行されるコマンドだが、strip_heredocs はデータと区別せず落とす。
  # gh 側と同型の穴で、この PR が作ったものではない。
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"bash <<EOF\ngit reset --hard\nEOF"}}'
  [ "$status" -ne 2 ]
}

@test "accepted gap: a false heredoc start whose tag reappears alone hides the command between" {
  # 復帰(D-38)は「終端タグ行が来ないまま EOF に達した」時だけ働く。誤認した開始のタグ語が
  # 後続行に単独で現れると偶発的に終端一致し、その間の行はバッファ破棄で消える。
  # タグが `shift` / `done` のような実スクリプトに現れる語でも同じ形が成立する。
  # lib 側の限界(resolve-git-target.sh の strip_heredocs ヘッダ)で、この hook では受容する。
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"echo \"cat << EOF で書く\"\ngit reset --hard\nEOF"}}'
  [ "$status" -ne 2 ]
}

@test "allows harmless git commands" {
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git status && git log --oneline -5"}}'
  [ "$status" -eq 0 ]
}

@test "guarded source: corrupt resolve-git-target lib fails open (exit != 2)" {
  echo "{ broken bash (" >"$HOME/.claude/hooks/lib/resolve-git-target.sh"
  run_hook block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git reset --hard"}}'
  [ "$status" -ne 2 ]
}

@test "fails open without jq (exit != 2)" {
  local nojq
  nojq="$(make_no_jq_path)"
  run_hook_env "$nojq" block-destructive-git.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git reset --hard"}}'
  [ "$status" -ne 2 ]
}
