#!/usr/bin/env bash
# PreToolUse(Bash): 未コミット作業を復元不能に破棄しうる git 操作をブロックする(dotfiles#72)。
# 対象: reset --hard / clean -f系 / stash drop・clear / branch -D(--delete + --force)。
# delegate 規約緩和(二段階の自己分類化)の補償として、客観条件を hook 層で担保する。
# 既存 block 系と同じ best-effort 字句検査(難読化は対象外)。人間は ! バイパスで実行可能。
# 安全側設計: jq 無し / 空コマンド / lib 不在なら exit 0(通す)。
set -euo pipefail

command -v jq &>/dev/null || exit 0
input="$(cat)"
cmd="$(echo "$input" | jq -r '.tool_input.command // empty')"
[[ -z "$cmd" ]] && exit 0

LIB="$HOME/.claude/hooks/lib/resolve-git-target.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
. "$LIB"

# lib に strip_heredocs があれば heredoc 本文を除去して誤爆を防ぐ(dotfiles#74 と合流後に有効化)。
if type strip_heredocs >/dev/null 2>&1; then
  stripped="$(strip_heredocs "$cmd" 2>/dev/null || true)"
  [[ -n "$stripped" ]] && cmd="$stripped"
fi

block() {
  echo "ブロック: $1 は未コミット作業や stash を復元不能に破棄しうるため禁止。人間が判断し、必要なら ! プレフィックスで実行すること。" >&2
  exit 2
}

while IFS= read -r seg; do
  [[ -z "$seg" ]] && continue
  case "$(git_subcommand_of_segment "$seg")" in
  reset)
    segment_has_option "$seg" --hard && block "git reset --hard"
    ;;
  clean)
    # -n(dry-run)等は許可し、実削除に必須の -f / --force だけを見る。
    segment_has_option "$seg" --force f && block "git clean -f"
    ;;
  stash)
    norm="$(normalized_words_of_segment "$seg")"
    if echo "$norm" | grep -qE '(^|[[:space:]])stash[[:space:]]+(drop|clear)([[:space:]]|$)'; then
      block "git stash drop/clear"
    fi
    ;;
  branch)
    # -d(merged 限定の安全削除)は許可。強制削除のみ止める。
    segment_has_option "$seg" "" D && block "git branch -D"
    if segment_has_option "$seg" --delete && segment_has_option "$seg" --force f; then
      block "git branch --delete --force"
    fi
    ;;
  esac
done < <(split_git_segments "$cmd")

exit 0
