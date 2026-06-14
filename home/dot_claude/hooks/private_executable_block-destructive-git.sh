#!/usr/bin/env bash
# PreToolUse(Bash): 未コミット作業を復元不能に破棄しうる git 操作をブロックする(dotfiles#72)。
# 対象: reset --hard / clean -f系 / stash drop・clear / branch 強制削除(-D とその等価形)/
#       restore(worktree 接触)/ checkout の変更破棄(-- / -f)/ worktree remove --force。
# delegate 規約緩和(二段階の自己分類化)の補償として、客観条件を hook 層で担保する。
# 既存 block 系と同じ best-effort 字句検査(難読化は対象外)。人間は ! バイパスで実行可能。
# 既知の限界(受容): long オプションの前方略記(--ha 等)・バックスラッシュ行継続は検出しない。
# 安全側設計: jq 無し / 空コマンド / lib 不在なら exit 0(通す)。
set -euo pipefail

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0
cmd="$(hook_command)"; [[ -z "$cmd" ]] && exit 0

RGT="$HOME/.claude/hooks/lib/resolve-git-target.sh"
[[ -r "$RGT" ]] || exit 0
# shellcheck source=/dev/null
. "$RGT"

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
    # 実削除に必須の -f / --force だけを見る。-n/--dry-run 併用(clean -nf 等)は
    # 削除しないため許可する。
    if ! segment_has_option "$seg" --dry-run n && segment_has_option "$seg" --force f; then
      block "git clean -f"
    fi
    ;;
  stash)
    norm="$(normalized_words_of_segment "$seg")"
    if echo "$norm" | grep -qE '(^|[[:space:]])stash[[:space:]]+(drop|clear)([[:space:]]|$)'; then
      block "git stash drop/clear"
    fi
    ;;
  branch)
    # -d(merged 限定の安全削除)は許可。強制削除(-D とその等価形 -df / --delete --force)のみ止める。
    segment_has_option "$seg" "" D && block "git branch -D"
    if segment_has_option "$seg" --delete d && segment_has_option "$seg" --force f; then
      block "git branch --delete --force"
    fi
    ;;
  restore)
    # --staged 単独(index のみ・worktree 非接触)は許可。それ以外は worktree の
    # 未コミット変更を破棄しうるため止める(-W/--worktree 明示を含む)。
    if segment_has_option "$seg" --worktree W || ! segment_has_option "$seg" --staged S; then
      block "git restore(worktree の変更破棄)"
    fi
    ;;
  checkout)
    # ブランチ切替・-b は許可。パス指定の変更破棄(--)と -f/--force のみ止める。
    norm="$(normalized_words_of_segment "$seg")"
    if printf '%s' " $norm " | grep -qE '[[:space:]]--[[:space:]]'; then
      block "git checkout -- <path>(変更破棄)"
    fi
    segment_has_option "$seg" --force f && block "git checkout -f"
    ;;
  worktree)
    norm="$(normalized_words_of_segment "$seg")"
    if printf '%s' "$norm" | grep -qE '(^|[[:space:]])worktree[[:space:]]+remove([[:space:]]|$)'; then
      segment_has_option "$seg" --force f && block "git worktree remove --force(dirty worktree の破棄)"
    fi
    ;;
  esac
done < <(split_git_segments "$cmd")

exit 0
