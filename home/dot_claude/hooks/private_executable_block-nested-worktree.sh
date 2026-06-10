#!/usr/bin/env bash
# PreToolUse(Bash): 素手の worktree 作成とネスト起動をブロックする。
# worktree 作成は bin/wt.sh 経由に強制し、フラット配置・正しい checkout・
# ネスト/二重 checkout 拒否をスクリプトに保証させる。安全側設計: jq 無しなら exit 0。
#
# 対象: git worktree add / gwq add / claude --worktree(-w)。
# 非対象: bin/wt.sh 経由の呼び出し(スクリプト内部の git worktree add は子プロセスで
#         この hook には見えない)。delegate の isolation:"worktree" は Bash コマンド
#         ではないので誤爆しない。heredoc 本文(issue 本文中のコマンド例等)は
#         strip_heredocs で除去してから照合する(dotfiles#74)。
set -euo pipefail

command -v jq &>/dev/null || exit 0
input="$(cat)"
cmd="$(echo "$input" | jq -r '.tool_input.command // empty')"
[[ -z "$cmd" ]] && exit 0

# lib が無い環境では素の cmd で従来どおり判定する(ブロック能力を落とさない)。
LIB="$HOME/.claude/hooks/lib/resolve-git-target.sh"
# shellcheck source=/dev/null
if [[ -r "$LIB" ]] && . "$LIB" 2>/dev/null; then
  stripped="$(strip_heredocs "$cmd" 2>/dev/null || true)"
  [[ -n "$stripped" ]] && cmd="$stripped"
fi

# wt.sh 経由は許可(誤ブロック防止)。
if echo "$cmd" | grep -qE '(^|/)wt\.sh(\s|$)'; then
  exit 0
fi

if echo "$cmd" | grep -qE '\bgit\s+worktree\s+add\b' ||
  echo "$cmd" | grep -qE '\bgwq\s+add\b' ||
  echo "$cmd" | grep -qE '\bclaude\b[^|;&]*\s(--worktree|-w)(\s|=|$)'; then
  echo "ブロック: worktree 作成は bin/wt.sh 経由に。素手の git worktree add / gwq add / claude --worktree(-w)は禁止(フラット配置・正 checkout・ネスト/二重 checkout 拒否を保証するため)。" >&2
  exit 2
fi

exit 0
