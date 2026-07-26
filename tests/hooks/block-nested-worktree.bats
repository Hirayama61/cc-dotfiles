#!/usr/bin/env bats
# block-nested-worktree.sh の E2E。素手の worktree 作成を止め、wt.sh 経由を通す境界と、
# heredoc 除去が許可側パターン(`wt.sh` early-exit)を復活させないことを固定する。
#
# 遮断は exit 2 のみ。fail-open の判定は「exit != 2」(このリポの規約)。

load ../helpers/common

setup() {
  install_hooks
}

@test "blocks bare git worktree add" {
  run_hook block-nested-worktree.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git worktree add ../wt-x feature/x"}}'
  [ "$status" -eq 2 ]
}

@test "blocks bare gwq add" {
  run_hook block-nested-worktree.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gwq add feature/x"}}'
  [ "$status" -eq 2 ]
}

@test "blocks claude --worktree" {
  run_hook block-nested-worktree.sh \
    '{"tool_name":"Bash","tool_input":{"command":"claude --worktree feature/x"}}'
  [ "$status" -eq 2 ]
}

@test "allows wt.sh" {
  run_hook block-nested-worktree.sh \
    '{"tool_name":"Bash","tool_input":{"command":"~/ghq/github.com/Hirayama61/dotfiles/bin/wt.sh feature/x"}}'
  [ "$status" -ne 2 ]
}

@test "allows a closed heredoc that documents git worktree add" {
  run_hook block-nested-worktree.sh \
    '{"tool_name":"Bash","tool_input":{"command":"cat <<EOF\ngit worktree add ../wt-x\nEOF"}}'
  [ "$status" -ne 2 ]
}

# この hook は許可側パターン(`wt.sh` に当たると exit 0)をコマンド全文へ掛けるため、
# 未終端 heredoc の本文を復帰させる strip_heredocs_lenient を使ってはいけない。
# 復帰させると、捨てられていた `wt.sh` 言及行が許可判定に当たり遮断が消える(実測で
# 2→0 に落ちた)。strict 版を使い続けていることをここで固定する。
@test "an unterminated false heredoc must not revive the wt.sh allow-path" {
  run_hook block-nested-worktree.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gwq add feature/x\necho \"a << b\"\n# bin/wt.sh"}}'
  [ "$status" -eq 2 ]
}
