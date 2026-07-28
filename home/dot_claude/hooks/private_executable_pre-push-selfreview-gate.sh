#!/usr/bin/env bash
# PreToolUse(Bash): セルフレビュー未通過のブランチからの push をブロックする。
# 目的は「push 禁止」ではなく「push 前に必ずセルフレビューを通す」強制。
# フラグは self-review スキルが通過時に作成する。
#
# 無効化の第一機構はフラグ内容の HEAD 束縛: フラグ 1 行目の `head: <sha>` を push 対象の
# 現 HEAD と突き合わせ、不一致ならブロックする(commit / amend / rebase / reset のいずれで
# HEAD が動いても、フラグ自身が古いと分かる)。commit 起点の削除
# (postcommit-invalidate-review.sh)は独立した二重の無効化として残っている。
# 書式の正典は flag-paths.sh(review_flag_head_line / review_flag_head_of)。
#
# 判定対象は hook プロセスの cwd ではなく push の実対象 working dir。これを
# resolve-git-target.sh で解決し、その dir の repo+branch でフラグキーを引く
# (dispatcher 型運用での別 repo/別 worktree push 誤ブロック対策)。
# フラグキーは flag-paths.sh(単一情報源)で導出する。gate(読取)/
# postcommit(削除)/SKILL(作成)の3者が同 lib を使いキー規約を完全一致させる。
# 保護ブランチ一覧は resolve-base-ref.sh が単一情報源。
# 安全側設計: 不明 / lib 不達なら exit 0。
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
source_hook_lib resolve-base-ref.sh || exit 0
source_hook_lib flag-paths.sh || exit 0

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

# 解除フラグは regular file のみ認める(-f は symlink を辿るため、予測可能パスへの symlink 設置で
# 解錠されるのを防ぐ。design-gate の読取側硬化と対称)。
if [[ ! -f "$flag_file" || -L "$flag_file" ]]; then
  echo "ブロック: ブランチ(${branch})は /self-review 未通過。push 前に /self-review を実施すること(通過でゲート解除。新規コミットで再レビュー必須)。" >&2
  exit 2
fi

# lib が古く head 束縛の関数が無い時は素通す(apply 前後で hook と lib の版がずれうる。
# 古い lib と組んで偽判定させない)。
type review_flag_head_of >/dev/null 2>&1 || exit 0

# HEAD が引けない(コミットの無いブランチ等)は判定材料が無いので素通す。
# `rev-parse HEAD` は解決に失敗しても stdout に "HEAD" を出すため空判定が効かない。
# --verify --quiet + ^{commit} なら失敗時に何も出さない。
current_head="$(git -C "$target_dir" rev-parse --verify --quiet "HEAD^{commit}" 2>/dev/null || echo "")"
[[ -z "$current_head" ]] && exit 0

recorded_head="$(review_flag_head_of "$flag_file")"
if [[ -z "$recorded_head" ]]; then
  echo "ブロック: ブランチ(${branch})の review-passed フラグに head 行が無い(旧形式 or 破損)。/self-review を再実施すること。" >&2
  exit 2
fi
if [[ "$recorded_head" != "$current_head" ]]; then
  echo "ブロック: レビュー済み HEAD(${recorded_head:0:7})と現在の HEAD(${current_head:0:7})が不一致。ブランチ(${branch})の成果物がレビュー後に変わっている。/self-review を再実施すること。" >&2
  exit 2
fi

exit 0
