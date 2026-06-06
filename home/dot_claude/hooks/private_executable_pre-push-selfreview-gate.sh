#!/usr/bin/env bash
# PreToolUse(Bash): セルフレビュー未通過のブランチからの push をブロックする。
# 目的は「push 禁止」ではなく「push 前に必ずセルフレビューを通す」強制。
# フラグは self-review スキルが通過時に作成する。コミットで無効化される
# (postcommit-invalidate-review.sh)。
#
# 判定対象は hook プロセスの cwd ではなく push の実対象 working dir。これを
# resolve-git-target.sh で解決し、その dir の repo+branch でフラグキーを引く
# (dispatcher 型運用での別 repo/別 worktree push 誤ブロック対策)。
# フラグキー = review-passed-${repo_key}--${safe_branch}。gate(読取)/
# postcommit(削除)/SKILL(作成)の3者でこのキー規約を完全一致させる。
# 安全側設計: 不明なら exit 0。
set -euo pipefail

command -v jq &>/dev/null || exit 0
input="$(cat)"
cmd="$(echo "$input" | jq -r '.tool_input.command // empty')"
[[ -z "$cmd" ]] && exit 0
cwd="$(echo "$input" | jq -r '.cwd // empty')"
[[ -z "$cwd" ]] && cwd="$PWD"

LIB="$HOME/.claude/hooks/lib/resolve-git-target.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
. "$LIB"

has_push=0
while IFS= read -r seg; do
  [[ -z "$seg" ]] && continue
  [[ "$(git_subcommand_of_segment "$seg")" == "push" ]] && has_push=1
done < <(split_git_segments "$cmd")
[[ "$has_push" -eq 0 ]] && exit 0

target_dir="$(resolve_git_target_dir "$cmd" "$cwd")"
git -C "$target_dir" rev-parse --is-inside-work-tree &>/dev/null || exit 0
branch="$(git -C "$target_dir" branch --show-current 2>/dev/null || echo "")"
[[ -z "$branch" ]] && exit 0

# 保護ブランチは block-protected-branch-push.sh が専任。ここでは二重メッセージを避け通す
case "$branch" in
main | master | develop | epic/*) exit 0 ;;
esac

REPO_RESOLVER="$HOME/.claude/hooks/lib/resolve-repo-key.sh"
repo_key=""
[[ -x "$REPO_RESOLVER" ]] && repo_key="$("$REPO_RESOLVER" "$target_dir" 2>/dev/null || true)"

# 空 repo_key はフラグキーを `review-passed---<branch>` に縮め同名 branch を持つ全 repo で
# 単一フラグを共有してしまう(repo A の通過が repo B の push を解除する)。3者キー一致
# (gate/postcommit/SKILL)が前提のためハッシュ代理は不採用。空時は安全側 block に倒す。
if [[ -z "$repo_key" ]]; then
  echo "ブロック: repo キーを解決できず /self-review フラグの repo スコープが保証できない(target=${target_dir})。${REPO_RESOLVER} が実行可能か(chezmoi apply 済か)を確認し、再度 push すること。" >&2
  exit 2
fi

safe_branch="$(echo "$branch" | tr '/' '-')"
flag_dir="/tmp/claude-sessions"
flag_file="${flag_dir}/review-passed-${repo_key}--${safe_branch}"
mkdir -p "$flag_dir"

if [[ ! -f "$flag_file" ]]; then
  echo "ブロック: ブランチ(${branch})は /self-review 未通過。push 前に /self-review を実施すること(通過でゲート解除。新規コミットで再レビュー必須)。" >&2
  exit 2
fi

exit 0
