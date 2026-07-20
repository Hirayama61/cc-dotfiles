#!/usr/bin/env bash
# main-clone-warn.sh — SessionStart(startup|resume|clear)
#
# cwd が main clone(~/ghq/ 配下のプライマリ作業ツリー)ならセッション冒頭に
# 「ここは編集不可、編集は worktree で」を additionalContext で 1 回注入する。
# block-main-clone-edit.sh(終端の砦)は残したまま、シグナルを作業開始時点へ前倒しし、
# 「作業の最後に編集して初めてブロックされ、そこまでの作業が無駄になる」手戻りを防ぐ
# (2026-07-11 監査トリアージ 争点3 で起案・確定。理由は Decisions)。
#
# 判定核は lib/resolve-main-clone.sh(単一情報源。block-main-clone-edit.sh と共有)。
# 対象が file_path でなく cwd である点だけが違う。
#
# 安全側設計: 警告注入の失敗でセッションを止めない。jq 不在 / lib 不達 / cwd 不明 /
# 相対 cwd / canonical 化失敗 / 非 git / linked worktree はすべて exit 0(無音)。
set -euo pipefail

# git 判定の核を環境変数注入で狂わされないよう無効化(block-main-clone-edit と同作法)。
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$LIB" ) >/dev/null 2>&1 || exit 0
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0

cwd="$(hook_cwd)"
[[ -z "$cwd" ]] && exit 0
# 相対 cwd は hook 実行ディレクトリ依存で別 repo を見に行くため判定しない(fail-open)。
[[ "$cwd" = /* ]] || exit 0
ccwd="$(cd "$cwd" 2>/dev/null && pwd -P || true)"
[[ -z "$ccwd" ]] && exit 0

# main clone 判定は lib が単一情報源(scope: canonical $HOME/ghq/ 配下 + プライマリ作業ツリー。
# linked worktree・非 ghq・非 git は非該当で無音)。
source_hook_lib resolve-main-clone.sh || exit 0
type is_main_clone >/dev/null 2>&1 || exit 0
is_main_clone "$ccwd" || exit 0

# jq は hook_init が存在を担保済み(不在なら上で exit 0 している)。

BODY="[main-clone-warn] 現在の作業ディレクトリ(${ccwd})は main clone(~/ghq/ のプライマリ作業ツリー)で、Claude からのファイル編集は block-main-clone-edit hook がブロックする(read/集約専用)。このリポのファイルを編集する作業なら、着手前に worktree を作ってそこで行うこと: cd \"\$(~/ghq/github.com/Hirayama61/dotfiles/bin/wt.sh <branch>)\"。読み取り・調査だけならこのままでよい。"

jq -n --arg body "$BODY" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $body
  }
}' || exit 0

exit 0
