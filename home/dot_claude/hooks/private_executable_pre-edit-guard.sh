#!/usr/bin/env bash
# pre-edit-guard.sh — PreToolUse hook (Edit|Write|MultiEdit)
#
# lint/format 設定・Claude Code hooks/設定・CI 設定・git フックの改竄を
# ブロックする。AI が品質ゲートや CI を勝手に書き換えて検査を素通しさせる
# 事故を防ぐ。
#
# chezmoi ソース除外の判定理由(なぜ */dot_claude/* でなく repo ルート相対 home/dot_* か):
#   本環境の規約では deploy 実体(~/.claude/..., ~/.config/...)を直接編集して
#   はならず、必ず chezmoi ソース(<repo>/home/dot_*)を編集して mise run apply
#   する。よって「repo ルート直下の home/dot_ = chezmoi ソース → 許可」「それ以外で
#   保護対象に合致 = deploy 実体 / 任意リポの CI・git フック → ブロック」が両リポの
#   レイアウトに最も整合する。
#   除外は repo ルート相対(rel)へアンカーする。非アンカー glob(*/home/dot_*)だと
#   /srv/home/dot_evil/.github/... のような任意深さの home/dot_ 配下を全許可し過剰除外に
#   なる(block-repo-doc は rel アンカーで正。本 hook を揃えた)。
set -euo pipefail

if ! command -v jq &>/dev/null; then
  exit 0
fi

input="$(cat)"
file_path="$(echo "$input" | jq -r '.tool_input.file_path // empty')"

if [[ -z "$file_path" ]]; then
  exit 0
fi

# 相対 file_path は保護パターンの先頭 */ アンカーと git -C が効かず判定が壊れるので
# 安全側で素通し(block-repo-doc / block-main-clone-edit と揃える)。Claude の Edit/Write は通常絶対パス。
[[ "$file_path" = /* ]] || exit 0

# chezmoi ソース(repo ルート直下の home/dot_*)は deploy 実体ではないので保護判定より先に通す。
# rel は git --show-toplevel(canonical)からの相対なので canonical_fp で算出する。
# git 外 / 非 repo-root の home/dot_ は除外せず下の保護判定へ落とす(deploy 実体を取りこぼさない)。
guard_dir="$(dirname -- "$file_path")"
guard_anchor="$(cd "$guard_dir" 2>/dev/null && pwd -P || true)"
if [[ -n "$guard_anchor" ]]; then
  toplevel="$(git -C "$guard_anchor" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$toplevel" ]]; then
    rel="${guard_anchor}/$(basename -- "$file_path")"
    rel="${rel#"$toplevel"/}"
    case "$rel" in
    home/dot_*) exit 0 ;;
    esac
  fi
fi

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
