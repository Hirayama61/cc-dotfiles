#!/usr/bin/env bash
# open-worktree.sh — 与えられた worktree 絶対パスを tmux のフル幅均等バンドで開く薄いラッパ。
#
# 機構(tmux 均等化ロジック)は持たず dotfiles の ~/.config/tmux/split-even.sh に委譲する
# (均等化ロジックを2箇所に複製しないため)。POLICY=どの worktree かは SKILL.md 側で
# Claude が解決し、ここには絶対パスだけ渡る。MECHANISM=開き方はこのスクリプトの責務。
#
# 依存: split-even.sh の `[path]` 引数対応(`split-even.sh v <path>`)。この対応は別の
# dotfiles PR で拡張中。path 非対応の旧 split-even.sh では引数が無視されアクティブ
# ペインのパスで開く点に注意(機能は壊れないが意図と異なる)。
set -euo pipefail

target="${1:-}"

if [ -z "${TMUX:-}" ]; then
  echo "open-worktree: tmux セッション内で実行してください(\$TMUX が空です)。" >&2
  exit 1
fi

if [ -z "$target" ]; then
  echo "usage: open-worktree.sh <worktree-絶対パス>" >&2
  exit 2
fi

# 開く対象は gwq/wt.sh の basedir(~/worktrees)配下の worktree のみに限定する。
# target は SKILL.md 経由で LLM が会話文脈から導出した値で、文脈汚染時に任意パス
# (~/.ssh 等)が紛れる経路になりうるため、正規 worktree root 配下だけ許可する。
case "$target" in
  "$HOME"/worktrees/*) ;;
  *) echo "open-worktree: worktree root(~/worktrees)配下の絶対パスを指定してください: $target" >&2; exit 2 ;;
esac

if [ ! -d "$target" ]; then
  echo "open-worktree: ディレクトリが存在しません: $target" >&2
  exit 1
fi

SPLIT_EVEN="$HOME/.config/tmux/split-even.sh"
if [ ! -x "$SPLIT_EVEN" ]; then
  echo "open-worktree: $SPLIT_EVEN が実行可能ではありません。dotfiles を apply 済みか確認してください(mise run apply)。" >&2
  exit 1
fi

exec "$SPLIT_EVEN" v "$target"
