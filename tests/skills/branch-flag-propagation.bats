#!/usr/bin/env bats
# branch フラグの伝播特性を回帰ガードする。別セッションを運転するワークフロー
# (pane-claude-drive のフラグ展開など)がこの 2 性質に依拠する。
#
# design-reviewed は repo+branch キーで session_id を含まない → 同一ブランチで起動する
# 別 session の被運転からも同じパスで見える。一方 design-reviewed-pending は branch を
# 含まない → 別ブランチへ漏れるので、運転元は用が済んだ pending を掃除する必要がある。
# ここではその 2 性質を flag-paths.sh の実キー導出で固定する。
#
# common.bash の install_hooks で一時 HOME に hooks/lib(executable_ を剥がす)を複製し、
# XDG_STATE_HOME を unset にして flag dir を一時 HOME 配下へ倒す(実 ~ に触れない)。

load ../helpers/common

setup() {
  install_hooks
  unset XDG_STATE_HOME
  FP="$HOME/.claude/hooks/lib/flag-paths.sh"
}

@test "design-reviewed flag is branch-scoped (different branches -> different paths)" {
  a="$("$FP" design-reviewed cc-dotfiles feat/one)"
  b="$("$FP" design-reviewed cc-dotfiles feat/two)"
  [ -n "$a" ]
  [ "$a" != "$b" ]
}

@test "design-reviewed flag is session-independent (same repo+branch -> identical path)" {
  # 別 session を模して 2 回導出。session_id を含まないなら完全一致する。
  a="$("$FP" design-reviewed cc-dotfiles feat/sample-task)"
  b="$("$FP" design-reviewed cc-dotfiles feat/sample-task)"
  [ "$a" = "$b" ]
  case "$a" in
  *feat-sample-task*) : ;;
  *) false ;;
  esac
}

@test "design-reviewed-pending is branch-agnostic (leaks across branches)" {
  # branch 引数を変えても同一パス = 別ブランチの別 session が取得しうる。
  p1="$("$FP" design-reviewed-pending cc-dotfiles)"
  p2="$("$FP" design-reviewed-pending cc-dotfiles)"
  [ "$p1" = "$p2" ]
  # branch フラグとは別物であること。
  br="$("$FP" design-reviewed cc-dotfiles feat/sample-task)"
  [ "$p1" != "$br" ]
}
