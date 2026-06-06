#!/usr/bin/env bash
# inject-coding-standards.sh — PreToolUse hook (Edit|Write|MultiEdit|NotebookEdit)
#
# コード編集の瞬間にコーディング規約を additionalContext として注入する。
# 注入順 = ① グローバル正典(~/.claude/coding-standards.md)→ ② 作業 repo 固有規約。
# additionalContext の出力形は pipe-stage-permissions.sh を流用。
#
# repo-aware(issue #42): 編集対象 file_path の git toplevel を辿り、AGENTS.md(無ければ
# project ルートの CLAUDE.md)があればグローバル規約の後ろに追記する。delegate / 独立
# コンテキスト起動の Claude はメイン会話を引き継がずグローバル規約しか持たないため、これが
# 無いと repo 固有のコーディング規約を踏み外す(delegate.md の鉄則1=規約取り込みと対の補強)。
# repo 固有を後ろに置くのは「より具体的な規約を後勝ちで効かせる」ため。
#
# 安全側設計: 注入の失敗で編集をブロックしない。jq 不在 / 規約不在 / 想定外のエラーは
# すべて exit 0 で素通り(コンテキスト注入は best-effort)。
set -euo pipefail

command -v jq &>/dev/null || exit 0

STD="$HOME/.claude/coding-standards.md"

# stdin から file_path を取得(repo 固有規約の探索起点)。matcher で対象を絞っているので
# ここに来た時点でコード編集ツール。jq 失敗時も素通りできるよう || true で握る。
input="$(cat || true)"
fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"

# 注入本文を組み立てる。グローバル正典 → repo 固有規約の順で連結。
body=""
[[ -f "$STD" ]] && body="$(cat "$STD")"

# 編集対象ファイルの git toplevel から AGENTS.md / CLAUDE.md を辿る。
# 相対パスは hook の cwd 依存で壊れるため絶対パスのときだけ(block-main-clone-edit 同様)。
if [[ "$fp" = /* ]]; then
  dir="$(dirname -- "$fp")"
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$root" ]]; then
    repo_std=""
    if [[ -f "$root/AGENTS.md" ]]; then
      repo_std="$root/AGENTS.md"
    elif [[ -f "$root/CLAUDE.md" ]]; then
      repo_std="$root/CLAUDE.md"
    fi
    if [[ -n "$repo_std" ]]; then
      repo_header="# 作業 repo 固有規約($repo_std)"
      repo_body="$(cat "$repo_std")"
      if [[ -n "$body" ]]; then
        body="$body"$'\n\n---\n\n'"$repo_header"$'\n\n'"$repo_body"
      else
        body="$repo_header"$'\n\n'"$repo_body"
      fi
    fi
  fi
fi

# 注入すべき本文が無ければ素通り(グローバル正典も repo 規約も無いケース)。
[[ -z "$body" ]] && exit 0

jq -n --arg body "$body" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: $body
  }
}' || exit 0

exit 0
