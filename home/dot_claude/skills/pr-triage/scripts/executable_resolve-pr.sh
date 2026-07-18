#!/usr/bin/env bash
# resolve-pr.sh — pr-triage の前提解決(対象 PR / repo / head ブランチの導出)。
#
# gh は $PWD に依存させず常に -R "$repo" で固定する(dispatcher/multi-worktree で別 repo の
# 同名 PR を誤操作しないため。ci-watch と同じ作法)。PR 番号は「引数最優先 → 無ければ現ブランチの
# open PR」の順で解決する(明示指定を最優先=誤 PR 対応を避ける)。実装の着手地点は「現ブランチ」で
# なく PR の head ブランチ(保護ブランチから明示 PR 番号で起動した場合に main を head と取り違えない)。
#
# 使い方: resolve-pr.sh [PR番号]
# 出力(成功時 exit 0): stdout に TAB 区切り 1 行 = `repo<TAB>owner<TAB>name<TAB>pr<TAB>head_branch`。
# exit コード:
#   0  … 成功(上記 1 行を stdout に出力)
#   2  … PR 番号引数が不正(正の整数でない)。stderr にメッセージ。
#   3  … 現ブランチに open PR が無い(clean stop)。stderr にメッセージ。呼び出し側は正常終了する。
#   1  … gh 未認証・ネットワーク不可等。stderr にメッセージ。
#   69 … gh 未導入。
set -euo pipefail

command -v gh >/dev/null 2>&1 || { echo "resolve-pr: gh 未導入。中断。" >&2; exit 69; }
gh auth status >/dev/null 2>&1 || { echo "resolve-pr: gh 未認証 or ネットワーク不可。認証してから再実行を。" >&2; exit 1; }

branch="$(git branch --show-current 2>/dev/null || true)"
repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"   # owner/repo
owner="${repo%%/*}"
name="${repo##*/}"

# PR 番号は「引数最優先 → 無ければ現ブランチの open PR」の順で解決する:
if [ -n "${1:-}" ]; then
  case "$1" in '' | 0 | 0* | *[!0-9]*) echo "resolve-pr: PR 番号は正の整数で指定する: $1" >&2; exit 2 ;; esac
  pr="$1"                                                           # 明示指定を最優先(誤 PR 対応を避ける)
else
  pr="$(gh pr list -R "$repo" --head "$branch" --state open --json number --jq '.[0].number')"
fi

# open PR が無ければ clean stop(後続の gh pr view "null" を避ける。head 解決の前に):
case "$pr" in '' | null) echo "resolve-pr: 現ブランチに open PR が無い。/pr-triage <PR番号> で明示を" >&2; exit 3 ;; esac

# 着手地点は PR の head ブランチ(保護ブランチ起点で main を head と取り違えないため):
head_branch="$(gh pr view "$pr" -R "$repo" --json headRefName --jq '.headRefName')"

printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$owner" "$name" "$pr" "$head_branch"
