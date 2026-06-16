#!/usr/bin/env bash
# ciwatch-on-push-nudge.sh — PostToolUse(Bash)
#
# `git push` の直後に、push 先ブランチに open PR があれば ci-watch するか判断せよとナッジする。
# gh pr create は作成時しか鳴らないので、追撃コミット(初回レビュー対応後の push)が死角だった。
# それを塞ぐ。ただし push は些細なこともあるので自動起動ではなく**ナッジ**(要否は Claude 判断)。
#
# 二重発火しない設計(Decisions #8): 初回 push 時点では PR 未作成 → open PR 無し → ナッジ無し →
# その後の gh pr create が自動起動を担う。追撃 push で初めて open PR ありを検知しナッジする。
#
# branch→PR は push 実対象 working dir 基準で解決する。cwd 結合だと dispatcher 型運用で
# cross-repo / 別 worktree push を誤判定する(Knowledge/pushゲートフックがプライマリrepo結合で
# cross-repo-push誤判定)。pre-push-selfreview-gate.sh と同じ resolve-git-target.sh を使う。
#
# 連続 push 抑制: 同一 PR への直近ナッジ時刻を mtime で記録し、5 分以内の再 push は抑制する
# (追撃の各ラウンドでは再ナッジしたいので PR ごと 1 回固定にはせず、連射だけをデバウンス)。
# macOS の BSD stat(-f %m)を使う(GNU stat -c %Y ではない)。
#
# 安全側設計: PostToolUse は tool 実行後なので exit 2 でブロックしても無意味。注入失敗で
# 止めない(jq 不在 / 非 push / 保護ブランチ / PR 無し / デバウンス中 はすべて exit 0)。
set -euo pipefail

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[ -r "$LIB" ] || exit 0
# shellcheck source=/dev/null
( . "$LIB" ) >/dev/null 2>&1 || exit 0
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0
cmd="$(hook_command)"; [ -z "$cmd" ] && exit 0
cwd="$(hook_cwd)"; [ -z "$cwd" ] && cwd="$PWD"

source_hook_lib resolve-git-target.sh || exit 0
source_hook_lib resolve-base-ref.sh || exit 0

# push サブコマンドの有無だけ見る。refspec(`HEAD:main` 等)の dst は解釈しないので、
# 現ブランチと異なる宛先への push でも現ブランチ基準でナッジしうる。block-protected-branch-push
# と同じ受容限界(best-effort・refspec push は稀)。挙動は変えない(PR #18 再レビュー B)。
has_push=0
while IFS= read -r seg; do
  [ -z "$seg" ] && continue
  [ "$(git_subcommand_of_segment "$seg")" = "push" ] && has_push=1
done < <(split_git_segments "$cmd")
[ "$has_push" -eq 0 ] && exit 0

target_dir="$(resolve_git_target_dir "$cmd" "$cwd")"
git -C "$target_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
branch="$(git -C "$target_dir" branch --show-current 2>/dev/null || echo "")"
[ -z "$branch" ] && exit 0

if is_protected_branch "$branch"; then
  exit 0
fi

command -v gh >/dev/null 2>&1 || exit 0
pr="$(cd "$target_dir" 2>/dev/null && gh pr list --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")"
{ [ -z "$pr" ] || [ "$pr" = "null" ]; } && exit 0

# repo キーはナッジ記録ファイル名の衝突回避用(別 repo の同番 PR を取り違えない)。
REPO_RESOLVER="$HOME/.claude/hooks/lib/resolve-repo-key.sh"
repo_key=""
[ -x "$REPO_RESOLVER" ] && repo_key="$("$REPO_RESOLVER" "$target_dir" 2>/dev/null || true)"
[ -n "$repo_key" ] || repo_key="unknown"

state_dir="/tmp/claude-sessions"
mkdir -p "$state_dir"
nudge_file="${state_dir}/ci-watch-nudge-${repo_key}-pr${pr}"
debounce=300

if [ -f "$nudge_file" ]; then
  last="$(stat -f %m "$nudge_file" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  [ $((now - last)) -lt "$debounce" ] && exit 0
fi

# poll-checks.sh が $PWD に依存せず対象 repo を見られるよう owner/repo を注入文に載せる
# (PR #18 CodeRabbit #1: pr-create hook と一貫させる)。push 実対象 dir 文脈で解決する。
repo_spec="$( (cd "$target_dir" && gh repo view --json nameWithOwner --jq '.nameWithOwner') 2>/dev/null || echo "")"
# repo が取れないなら無音 exit。空のまま注入すると poll-checks が $PWD fallback に落ち、
# dispatcher 運用で誤 repo を監視する穴が復活する(PR #18 再レビュー #4 = pr-create の #A と対称)。
{ [ -z "$repo_spec" ] || [ "$repo_spec" = "null" ]; } && exit 0

NOTE="push 先ブランチ(${branch})に open PR #${pr} がある。追撃コミットなら ci-watch を回すか判断せよ: 回すなら Bash ツールを run_in_background:true で \`~/.claude/skills/ci-watch/scripts/poll-checks.sh ${pr} ${repo_spec}\` を起動し、起床後に評価フェーズを実行する(返信も適用もしない)。些細な push なら不要。"

# debounce の mtime 更新は注入が確定した後にだけ行う。jq 失敗時に mtime だけ進むと、
# ナッジ未注入なのに以後 debounce 窓で再ナッジが抑制され追撃 push の死角が再発する(F-003)。
out="$(jq -n --arg body "$NOTE" '{
  hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: $body }
}')" || exit 0
printf '%s\n' "$out"
: >"$nudge_file"

exit 0
