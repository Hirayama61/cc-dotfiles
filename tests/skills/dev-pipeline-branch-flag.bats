#!/usr/bin/env bats
# dev-pipeline が依拠する F-A の前提(branch フラグ伝播)を回帰ガードする。
#
# design-reviewed は repo+branch キーで session_id を含まない → 同一ブランチで起動する
# 別 session の被運転からも同じパスで見える(Plan v2 §3/§7.1)。一方 design-reviewed-pending
# は branch を含まない → 別ブランチへ漏れる。dev-pipeline SKILL はこの pending を Phase 0 後に
# 掃除する(V2-M-04)。ここではその 2 性質を flag-paths.sh の実キー導出で固定する。
#
# common.bash の install_hooks で一時 HOME に hooks/lib(executable_ を剥がす)を複製し、
# XDG_STATE_HOME を unset にして flag dir を一時 HOME 配下へ倒す(実 ~ に触れない)。

load ../helpers/common

setup() {
  install_hooks
  unset XDG_STATE_HOME
  FP="$HOME/.claude/hooks/lib/flag-paths.sh"
}

@test "design-reviewed flag is branch-scoped (different branches → different paths)" {
  a="$("$FP" design-reviewed cc-dotfiles feat/one)"
  b="$("$FP" design-reviewed cc-dotfiles feat/two)"
  [ -n "$a" ]
  [ "$a" != "$b" ]
}

@test "design-reviewed flag is session-independent (same repo+branch → identical path)" {
  # 別 session を模して 2 回導出。session_id を含まないなら完全一致する(F-A の要)。
  a="$("$FP" design-reviewed cc-dotfiles feat/dev-pipeline)"
  b="$("$FP" design-reviewed cc-dotfiles feat/dev-pipeline)"
  [ "$a" = "$b" ]
  case "$a" in
  *feat-dev-pipeline*) : ;;
  *) false ;;
  esac
}

@test "design-reviewed-pending is branch-agnostic (leak dev-pipeline cleans up)" {
  # branch 引数を変えても同一パス = 別ブランチの別 session が取得しうる(V2-M-04)。
  p1="$("$FP" design-reviewed-pending cc-dotfiles)"
  p2="$("$FP" design-reviewed-pending cc-dotfiles)"
  [ "$p1" = "$p2" ]
  # branch フラグとは別物であること。
  br="$("$FP" design-reviewed cc-dotfiles feat/dev-pipeline)"
  [ "$p1" != "$br" ]
}
