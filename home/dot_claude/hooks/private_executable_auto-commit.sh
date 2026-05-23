#!/usr/bin/env bash
# Stop hook: Claude 停止時に tracked の変更だけを機械的に wip コミットする。
# 「作業が終わったら毎回自動でコミット(push はしない)」を全プロジェクトで実現。
#
# 設計:
# - tracked のみ対象(git add -u)。新規 untracked は add しない(.research/ 等のゴミ回避)。
# - 変更が無ければ無動作 → コミット後は clean になり再発火しても無動作(無限ループしない)。
#   加えて stop_hook_active で二重防御。
# - push は絶対にしない。--no-verify も使わない(グローバル pre-commit ガードを通す)。
# - commit 失敗(機密語/secretlint 等)は Stop を妨げない: exit 0 + systemMessage で通知。
set -euo pipefail

command -v jq &>/dev/null || exit 0
input="$(cat)"

# 無限ループ防止: 既に Stop hook 起因の継続中なら何もしない。
[[ "$(echo "$input" | jq -r '.stop_hook_active // false')" == "true" ]] && exit 0

# git リポでなければ何もしない(プロセス cwd 前提。既存 hook と同様)。
git rev-parse --is-inside-work-tree &>/dev/null 2>&1 || exit 0

# 保護ブランチ / ブランチ不明では wip を作らない。block-protected-branch-push.sh が
# 保護ブランチへの push を禁じるため、ここで wip を作ると送れず溜まる一方になる。
branch="$(git branch --show-current 2>/dev/null || echo "")"
case "$branch" in
"" | main | master | develop | epic/*) exit 0 ;;
esac

# tracked の変更(working tree / index)が無ければ無動作。
if git diff --quiet && git diff --cached --quiet; then
  exit 0
fi

# tracked の変更/削除のみステージ。新規 untracked は入らない。
git add -u

# add -u の結果ステージが空(tracked 変更が実質無かった)なら無動作。
if git diff --cached --quiet; then
  exit 0
fi

msg="wip: auto-commit $(date '+%Y-%m-%d %H:%M:%S')"

# commit 失敗時も Stop を妨げない(exit 2 / decision:block は使わない)。
# stderr を捕捉し、失敗なら systemMessage でユーザーに通知して exit 0。
if ! commit_err="$(git commit -m "$msg" 2>&1)"; then
  jq -n --arg err "$commit_err" '{
    systemMessage: ("auto-commit 失敗: pre-commit ガード等でコミットできませんでした。手動で対処してください。\n" + $err)
  }'
  exit 0
fi

exit 0
