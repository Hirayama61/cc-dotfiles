#!/usr/bin/env bash
# block-repo-doc.sh — PreToolUse(Write): doc-gravity 強制
#
# git リポ作業ツリー配下の「新規 .md 生成」をブロックし、作業ドキュメント
# (plan/report/findings 等)を ~/obsidian/brain/Tasks/<repo>/ へ誘導する。
# ext-skills 等が規約を無視してリポ配下にドキュメントを撒く事故を構造的に止める。
#
# 安全側設計: jq 不在 / path 不明 / 除外パス / 既存ファイル / git 外 / dev doc 許可
# はすべて exit 0(素通し)。ブロックは「git 配下 ∧ 新規 ∧ .md ∧ 非許可」の AND が
# 全部立った時だけ exit 2。Edit/MultiEdit は settings の matcher="Write" で除外される
# (既存編集スルーの決定と整合させるため hook 内で tool_name も再確認する)。
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
[[ "$tool_name" == "Write" ]] || exit 0

fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
[[ -z "$fp" ]] && exit 0

case "$fp" in
*.md) ;;
*) exit 0 ;;
esac

# スコープ除外(いずれか該当で素通し):
#   - vault 自身 / 一時領域(macOS の /tmp 実体 /private/tmp・/var/folders 含む)
#   - */.claude/*(live ~/.claude/** と各リポの .claude/** の双方。skill/hook/agent 定義)
#   - */home/dot_*(chezmoi ソース全般。dotfiles/cc-dotfiles の正当な新規 .md を誤爆しない)
case "$fp" in
"$HOME"/obsidian/brain/*) exit 0 ;;
/tmp/* | /private/tmp/* | /var/folders/*) exit 0 ;;
*/.claude/*) exit 0 ;;
*/home/dot_*) exit 0 ;;
esac

# 既存ファイルの上書きは常に許可(新規生成だけブロック)。
[[ -e "$fp" ]] && exit 0

dir="$(dirname -- "$fp")"
toplevel="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$toplevel" ]] && exit 0

base="$(basename -- "$fp")"
case "$base" in
README.md | CONTRIBUTING.md | CHANGELOG.md | LICENSE.md | CLAUDE.md | AGENTS.md | SECURITY.md) exit 0 ;;
esac

# docs/** と .github/** 配下は dev doc として通す(toplevel からの相対で判定)。
rel="${fp#"$toplevel"/}"
case "$rel" in
docs/* | .github/*) exit 0 ;;
esac

repo_key="$("$HOME/.claude/hooks/lib/resolve-repo-key.sh" "$dir" 2>/dev/null || true)"
: "${repo_key:=$(basename -- "$toplevel")}"

{
  echo "ブロック: リポ配下の新規ドキュメント生成は禁止です: $fp"
  echo "作業ドキュメント(plan/report/findings 等)は外部脳へ書いてください:"
  echo "  ~/obsidian/brain/Tasks/${repo_key}/<トピック>.md"
  echo "(dev doc は README/CONTRIBUTING/CHANGELOG/LICENSE/CLAUDE/AGENTS/SECURITY, docs/**, .github/** のみ許可。既存 .md の編集は許可)"
} >&2
exit 2
