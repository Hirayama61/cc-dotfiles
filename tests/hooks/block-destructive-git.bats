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
