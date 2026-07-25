#!/usr/bin/env bats
# block-force-push.sh の E2E。「push セグメント内の force 系フラグだけを止める」という
# 実装の骨格(git_subcommand_of_segment による push 厳密一致 + segment_has_option の
# quote-aware 判定)を、止める側/通す側の両面で固定する。
#
# 遮断は exit 2 のみ。fail-open の判定は「exit != 2」(このリポの規約)だが、本 hook の
# 素通し経路は全て exit 0 に収束するため下では 0 を直接確認する。

load ../helpers/common

setup() {
  install_hooks
}

@test "blocks git push --force" {
  run_hook block-force-push.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
  [ "$status" -eq 2 ]
}

@test "blocks git push -f (short flag)" {
  run_hook block-force-push.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git push -f origin main"}}'
  [ "$status" -eq 2 ]
}

@test "blocks git push -uf (bundled short flag)" {
  run_hook block-force-push.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git push -uf origin main"}}'
  [ "$status" -eq 2 ]
}

@test "blocks git push --force-with-lease" {
  run_hook block-force-push.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git push --force-with-lease origin main"}}'
  [ "$status" -eq 2 ]
}

@test "blocks git push --force-with-lease=<refspec> (flag with a value)" {
  # 値付きフラグは = で1トークンに癒着するため、完全一致だけの判定だと取りこぼす。
  # 検証しているのは --force-with-lease=値 であって --force=値 ではない。
  run_hook block-force-push.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git push --force-with-lease=main:abc123 origin main"}}'
  [ "$status" -eq 2 ]
}

@test "blocks git push --force-if-includes" {
  run_hook block-force-push.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git push --force-if-includes origin main"}}'
  [ "$status" -eq 2 ]
}

@test "blocks a quoted --force flag" {
  # 字句 grep 型 hook がクォート付きフラグを取りこぼす層 (a) の回帰防止。
  run_hook block-force-push.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git push \"--force\" origin main"}}'
  [ "$status" -eq 2 ]
}

@test "blocks force push in a later segment of a chain" {
  run_hook block-force-push.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git status && git push --force"}}'
  [ "$status" -eq 2 ]
}

@test "allows a normal push" {
  run_hook block-force-push.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
  [ "$status" -eq 0 ]
}

@test "allows git push --set-upstream (long flag without force)" {
  # 短縮 -f 判定が --set-upstream の 'f' を拾わないこと(--* は短縮束から除外される)。
  run_hook block-force-push.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git push --set-upstream origin feature/x"}}'
  [ "$status" -eq 0 ]
}

@test "allows force flags on non-push subcommands" {
  # force 判定は push セグメントに限定される(git fetch --force は対象外)。
  run_hook block-force-push.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git fetch --force origin"}}'
  [ "$status" -eq 0 ]
}

@test "no false positive: force push inside a string literal is allowed" {
  # クォートが割れたトークン("git)は git 語として認識されないため push 判定に入らない。
  run_hook block-force-push.sh \
    '{"tool_name":"Bash","tool_input":{"command":"echo \"git push --force\" && git push origin main"}}'
  [ "$status" -eq 0 ]
}

@test "guarded source: corrupt resolve-git-target lib fails open (exit 0)" {
  # 入力は smoke-all.bats の全 hook 一括版(`git push --force`)と重ならない値付き形にする。
  echo "{ broken bash (" >"$HOME/.claude/hooks/lib/resolve-git-target.sh"
  run_hook block-force-push.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git push --force-with-lease=main:abc123"}}'
  [ "$status" -eq 0 ]
}

@test "fails open without jq (exit 0)" {
  # jq はどのリポも宣言しておらず macOS 同梱に依存する(不在は現実に起こる)。
  # ヘッダの宣言どおり 0 を直接見る — -ne 2 だと exit 127 のクラッシュを見逃す。
  local nojq
  nojq="$(make_no_jq_path)"
  run_hook_env "$nojq" block-force-push.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git push --force"}}'
  [ "$status" -eq 0 ]
}
