#!/usr/bin/env bash
# PreToolUse(Bash): 保護ブランチ(main/master/develop/epic/**)への
# push / merge を物理的にブロックする。人間の許可なき不可逆操作を防ぐ。
#
# 判定対象は hook プロセスの cwd ではなく、コマンドが実際に操作する working dir。
# `cd <wt> && git push` / `git -C <wt> push` の実対象を resolve-git-target.sh で
# 解決し、その dir の現在ブランチで判定する(dispatcher 型運用での cross-repo /
# 別 worktree push 誤ブロック対策。RCA: Knowledge/pushゲートフックがプライマリ
# repo結合でcross-repo-push誤判定.md)。保護判定は現在ブランチ基準のみ。
#
# 既知の限界(意図的・CodeRabbit PR #4 で再提起したが現状維持を選択): `git push origin
# HEAD:main` 等の明示 refspec で宛先の保護ブランチを更新する経路は検知しない。自分の
# Claude を縛る best-effort ゲートであり、refspec(src:dst / refs/heads/* / --delete)解析の
# 誤爆・漏れリスクを避けるため受容する。
#
# 安全側設計: jq 無し / git 外 / ブランチ不明なら exit 0(通す)。
# 検知は best-effort(難読化は素通る)であり敵対防御ではない。
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

# セグメント分割 + サブコマンド厳密一致で push / merge を検出。
# merge-base/merge-tree/merge-file や `git log | grep push` 等の誤爆を避ける。
has_push=0
has_merge=0
while IFS= read -r seg; do
  [[ -z "$seg" ]] && continue
  case "$(git_subcommand_of_segment "$seg")" in
  push) has_push=1 ;;
  merge) has_merge=1 ;;
  esac
done < <(split_git_segments "$cmd")
[[ "$has_push" -eq 0 && "$has_merge" -eq 0 ]] && exit 0

target_dir="$(resolve_git_target_dir "$cmd" "$cwd")"
git -C "$target_dir" rev-parse --is-inside-work-tree &>/dev/null || exit 0
branch="$(git -C "$target_dir" branch --show-current 2>/dev/null || echo "")"
[[ -z "$branch" ]] && exit 0

is_protected() {
  [[ "$1" == "main" || "$1" == "master" || "$1" == "develop" || "$1" == epic/* ]]
}

if [[ "$has_push" -eq 1 ]] && is_protected "$branch"; then
  echo "ブロック: 保護ブランチ(${branch})への push は禁止。feature ブランチから人間が PR を作成すること。" >&2
  exit 2
fi

if [[ "$has_merge" -eq 1 ]] && is_protected "$branch"; then
  echo "ブロック: 保護ブランチ(${branch})への merge は禁止。人間の判断を経ること。" >&2
  exit 2
fi

exit 0
