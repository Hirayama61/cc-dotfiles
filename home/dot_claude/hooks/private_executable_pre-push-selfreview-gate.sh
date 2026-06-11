#!/usr/bin/env bash
# PreToolUse(Bash): セルフレビュー未通過のブランチからの push をブロックする。
# 目的は「push 禁止」ではなく「push 前に必ずセルフレビューを通す」強制。
# フラグは self-review スキルが通過時に作成する。コミットで無効化される
# (postcommit-invalidate-review.sh)。
#
# 判定対象は hook プロセスの cwd ではなく push の実対象 working dir。これを
# resolve-git-target.sh で解決し、その dir の repo+branch でフラグキーを引く
# (dispatcher 型運用での別 repo/別 worktree push 誤ブロック対策)。
# フラグキーは flag-paths.sh(単一情報源)で導出する。gate(読取)/
# postcommit(削除)/SKILL(作成)の3者が同 lib を使いキー規約を完全一致させる。
# 保護ブランチ一覧は resolve-base-ref.sh が単一情報源。
# 安全側設計: 不明 / lib 不達なら exit 0。
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
BASE_LIB="$HOME/.claude/hooks/lib/resolve-base-ref.sh"
[[ -r "$BASE_LIB" ]] || exit 0
# shellcheck source=/dev/null
. "$BASE_LIB"
FLAG_LIB="$HOME/.claude/hooks/lib/flag-paths.sh"
[[ -r "$FLAG_LIB" ]] || exit 0
# shellcheck source=/dev/null
. "$FLAG_LIB"

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
if is_protected_branch "$branch"; then
  exit 0
fi

REPO_RESOLVER="$HOME/.claude/hooks/lib/resolve-repo-key.sh"
repo_key=""
[[ -x "$REPO_RESOLVER" ]] && repo_key="$("$REPO_RESOLVER" "$target_dir" 2>/dev/null || true)"

flag_file="$(review_passed_flag "$repo_key" "$branch")"

if [[ ! -f "$flag_file" ]]; then
  echo "ブロック: ブランチ(${branch})は /self-review 未通過。push 前に /self-review を実施すること(通過でゲート解除。新規コミットで再レビュー必須)。" >&2
  exit 2
fi

exit 0
