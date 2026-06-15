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
# 保護ブランチ一覧は resolve-base-ref.sh の is_protected_branch が単一情報源。
#
# 安全側設計: jq 無し / git 外 / ブランチ不明 / lib 不達なら exit 0(通す)。
# 検知は best-effort(難読化は素通る)であり敵対防御ではない。
set -euo pipefail

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$LIB" ) >/dev/null 2>&1 || exit 0
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0
cmd="$(hook_command)"; [[ -z "$cmd" ]] && exit 0
cwd="$(hook_cwd)"; [[ -z "$cwd" ]] && cwd="$PWD"

RGT="$HOME/.claude/hooks/lib/resolve-git-target.sh"
[[ -r "$RGT" ]] || exit 0
# shellcheck source=/dev/null
. "$RGT"
BASE_LIB="$HOME/.claude/hooks/lib/resolve-base-ref.sh"
[[ -r "$BASE_LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$BASE_LIB" ) >/dev/null 2>&1 || exit 0
. "$BASE_LIB" 2>/dev/null || exit 0

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

if [[ "$has_push" -eq 1 ]] && is_protected_branch "$branch"; then
  echo "ブロック: 保護ブランチ(${branch})への push は禁止。feature ブランチから人間が PR を作成すること。" >&2
  exit 2
fi

if [[ "$has_merge" -eq 1 ]] && is_protected_branch "$branch"; then
  echo "ブロック: 保護ブランチ(${branch})への merge は禁止。人間の判断を経ること。" >&2
  exit 2
fi

exit 0
