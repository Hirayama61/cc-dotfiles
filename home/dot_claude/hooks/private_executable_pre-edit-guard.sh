#!/usr/bin/env bash
# pre-edit-guard.sh — PreToolUse hook (Edit|Write|MultiEdit)
#
# lint/format 設定・Claude Code hooks/設定・CI 設定・git フックの改竄を
# ブロックする。AI が品質ゲートや CI を勝手に書き換えて検査を素通しさせる
# 事故を防ぐ。
#
# chezmoi ソース除外の判定理由(なぜ */dot_claude/* でなく */home/dot_* か):
#   本環境の規約では deploy 実体(~/.claude/..., ~/.config/...)を直接編集して
#   はならず、必ず chezmoi ソース(.../home/dot_*)を編集して mise run apply
#   する。よって「パスに /home/dot_ セグメントを含む = chezmoi ソース → 許可」
#   「それ以外で保護対象に合致 = deploy 実体 / 任意リポの CI・git フック →
#   ブロック」が両リポのレイアウトに最も整合する。参考にした */dot_claude/* は
#   lint/CI のソースを取りこぼすため /home/dot_ セグメント判定に作り直した。
set -euo pipefail

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0
file_path="$(hook_file_path)"

if [[ -z "$file_path" ]]; then
  exit 0
fi

# chezmoi ソースは deploy 実体ではないので保護対象パターンより先に通す。
case "$file_path" in
*/home/dot_*)
  exit 0
  ;;
esac

case "$file_path" in
*/.claude/hooks/* | */.claude/settings.json* | */.claude/settings.local.json* | \
  */biome.json | */.eslintrc* | */eslint.config.* | */.prettierrc* | */prettier.config.* | */.stylelintrc* | \
  */.github/workflows/* | */.gitlab-ci.yml | \
  */.config/git/hooks/* | \
  */.hooks/* | */.husky/* | */.lefthook.yml | */lefthook.yml)
  echo "ブロック: ${file_path} は保護対象(品質ゲート/CI/フック設定)です。chezmoi ソース(.../home/dot_*)を編集して mise run apply するか、本当に必要ならユーザーに確認してください。" >&2
  exit 2
  ;;
esac

exit 0
