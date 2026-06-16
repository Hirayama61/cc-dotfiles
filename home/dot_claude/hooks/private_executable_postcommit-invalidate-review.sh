#!/usr/bin/env bash
# PostToolUse(Bash): git commit 実行後、そのブランチのセルフレビュー
# フラグを削除する。これにより「現在の成果物をレビューせず push」が
# 物理的に不可能になる(コミットのたびに再レビュー必須)。
#
# フラグキーは flag-paths.sh(単一情報源)で導出する。gate(読取)/
# postcommit(削除)/SKILL(作成)の3者が同 lib を使う。commit の実対象 working dir を
# resolve-git-target.sh で解決し、その dir の repo+branch でキーを引く(別 repo/
# 別 worktree での commit を取り違えないため)。
# 安全側設計: 不明 / lib 不達なら静かに exit 0(削除=保守的なので消し過ぎは無害。
# lib 不達時は gate 側も同様に exit 0 するためゲート全体が fail-open で整合)。
set -euo pipefail

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$LIB" ) >/dev/null 2>&1 || exit 0
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0
cmd="$(hook_command)"; [[ -z "$cmd" ]] && exit 0
cwd="$(hook_cwd)"; [[ -z "$cwd" ]] && cwd="$PWD"

source_hook_lib resolve-git-target.sh || exit 0
source_hook_lib flag-paths.sh || exit 0

has_commit=0
while IFS= read -r seg; do
  [[ -z "$seg" ]] && continue
  [[ "$(git_subcommand_of_segment "$seg")" == "commit" ]] && has_commit=1
done < <(split_git_segments "$cmd")
[[ "$has_commit" -eq 0 ]] && exit 0

target_dir="$(resolve_git_target_dir "$cmd" "$cwd")"
git -C "$target_dir" rev-parse --is-inside-work-tree &>/dev/null || exit 0
branch="$(git -C "$target_dir" branch --show-current 2>/dev/null || echo "")"
[[ -z "$branch" ]] && exit 0

REPO_RESOLVER="$HOME/.claude/hooks/lib/resolve-repo-key.sh"
repo_key=""
[[ -x "$REPO_RESOLVER" ]] && repo_key="$("$REPO_RESOLVER" "$target_dir" 2>/dev/null || true)"

rm -f "$(review_passed_flag "$repo_key" "$branch")"

exit 0
