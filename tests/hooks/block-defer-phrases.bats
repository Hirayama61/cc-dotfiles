#!/usr/bin/env bats
# block-defer-phrases.sh の E2E。本文の先送り表現を止め、追跡参照(#番号)付きを通す
# 境界と、heredoc 除去が許可側パターン(`(#NNN)` の continue)を復活させないことを固定する。
#
# 遮断は exit 2 のみ。fail-open の判定は「exit != 2」(このリポの規約)。

load ../helpers/common

setup() {
  install_hooks
}

@test "blocks git commit whose message defers silently" {
  run_hook block-defer-phrases.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"out of scope\""}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr comment whose body defers silently" {
  run_hook block-defer-phrases.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr comment 1 --body \"後で対応\""}}'
  [ "$status" -eq 2 ]
}

@test "allows a defer phrase that carries a tracking reference" {
  run_hook block-defer-phrases.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"out of scope (#123)\""}}'
  [ "$status" -ne 2 ]
}

@test "allows a commit message without any defer phrase" {
  run_hook block-defer-phrases.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix: close the gap\""}}'
  [ "$status" -ne 2 ]
}

# この hook は許可側パターン(`(#NNN)` に当たると continue)をコマンド全文へ掛けるため、
# 未終端 heredoc の本文を復帰させる strip_heredocs_lenient を使ってはいけない。
# 復帰させると、捨てられていた `(#123)` 言及行が許可判定に当たり遮断が消える(実測で
# 2→0 に落ちた)。strict 版を使い続けていることをここで固定する。
@test "an unterminated false heredoc must not revive the (#NNN) allow-path" {
  run_hook block-defer-phrases.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"out of scope\"\necho \"a << b\"\necho \"(#123)\""}}'
  [ "$status" -eq 2 ]
}
