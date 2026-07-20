#!/usr/bin/env bash
# resolve-main-clone.sh — main clone(~/ghq/ 配下のプライマリ作業ツリー)判定の単一情報源。
# block-main-clone-edit.sh(編集ブロック)と main-clone-warn.sh(SessionStart 警告)が共有する。
# 2026-07-19 に両 hook のインライン複製を集約(HOME canonical 化の有無で 2 コピーが乖離した
# drift の実測を受けて。経緯は Decisions)。
#
# source 前提(set 状態を汚染しない)。呼び出し側は source_hook_lib で読み、
# `type is_main_clone` で存在検査してから使うこと。
#
# 呼び出し側の責務: GIT_DIR / GIT_WORK_TREE / GIT_COMMON_DIR / GIT_INDEX_FILE /
# GIT_OBJECT_DIRECTORY の unset(環境変数注入で git 判定核を狂わされない対策)は
# hook 冒頭で行う(本 lib は環境を変更しない)。

# is_main_clone <canonical-dir>
# <canonical-dir> は pwd -P 済みの絶対実在パスであること(呼び出し側が canonical 化する)。
# return 0: main clone(canonical $HOME/ghq/ 配下 かつ プライマリ作業ツリー)
# return 1: それ以外(非 ghq / 非 git / linked worktree / 判定不能はすべて 1 = 安全側)
#
# 判定の要点(元 block-main-clone-edit.sh のコメントを継承):
# - scope は canonical 化した $HOME/ghq/ 配下のみ(~/worktrees/・~/obsidian 等は非対象)。
#   HOME 側も canonical 化する(macOS の /var→/private/var 等の symlink で、pwd -P 済みの
#   dir との接頭辞照合が外れるのを防ぐ)。
# - --is-inside-work-tree は work-tree 外でも exit 0 + 出力 "false" を返すので
#   exit code でなく出力 == true を見る。
# - プライマリ判定は --git-dir == --git-common-dir(linked worktree は不一致)。
#   git-dir/common-dir が空だと cd "" で cwd 据え置き → 誤一致になるため空を明示的に弾く。
is_main_clone() {
  local dir="${1:-}" chome rel_gd rel_gcd gd gcd
  [[ -n "$dir" ]] || return 1

  chome="$(cd "$HOME" 2>/dev/null && pwd -P || printf '%s' "$HOME")"
  case "$dir" in
  "$chome"/ghq/*) ;;
  *) return 1 ;;
  esac

  [[ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]] || return 1
  rel_gd="$(git -C "$dir" rev-parse --git-dir 2>/dev/null || true)"
  rel_gcd="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null || true)"
  [[ -z "$rel_gd" || -z "$rel_gcd" ]] && return 1
  gd="$(cd "$dir" && cd "$rel_gd" 2>/dev/null && pwd -P || true)"
  gcd="$(cd "$dir" && cd "$rel_gcd" 2>/dev/null && pwd -P || true)"
  [[ -z "$gd" || -z "$gcd" || "$gd" != "$gcd" ]] && return 1
  return 0
}
