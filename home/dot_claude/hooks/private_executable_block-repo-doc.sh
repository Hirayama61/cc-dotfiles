#!/usr/bin/env bash
# block-repo-doc.sh — PreToolUse(Write): doc-gravity 強制
#
# git リポ作業ツリー配下の「新規 .md 生成」をブロックし、作業ドキュメント
# (plan/report/findings 等)を ~/obsidian/brain/Tasks/<repo>/ へ誘導する。
# ext-skills 等が規約を無視してリポ配下にドキュメントを撒く事故を構造的に止める。
#
# 安全側設計: jq 不在 / path 不明 / 相対パス / 除外パス / 既存ファイル / git 外 /
# dev doc 許可はすべて exit 0(素通し)。ブロックは「git 配下 ∧ 新規 ∧ .md ∧ 非許可」の
# AND が全部立った時だけ exit 2。Edit/MultiEdit は settings の matcher="Write" で除外される
# (既存編集スルーの決定と整合させるため hook 内で tool_name も再確認する)。
#
# 判定順序: 絶対パスガード → .md 判定 → tool=Write → canonical 化 →
#   vault/tmp/.claude 除外 → 既存ファイル素通し → toplevel 算出(無ければ exit0)→
#   rel 算出 → home/dot_* 除外(rel アンカー)→ 許可リスト/docs/.github → else exit2。
set -euo pipefail

# 親 dir が未存在でも canonical 化する。Write は中間ディレクトリを自動生成するため、
# 新規サブディレクトリへの新規 .md(reports/x.md 等)を素通ししないよう最近接既存祖先まで
# 遡って解決し未存在の tail を再付与する。CANON_DIR=正規化 dir / GIT_ANCHOR=git -C 用の
# 実在祖先(未存在 dir を git -C に渡すと fail するため分離)。総失敗時は両方空。
CANON_DIR=""
GIT_ANCHOR=""
canonicalize_dir() {
  local dir="$1" tail="" base parent
  while [[ -n "$dir" && ! -d "$dir" ]]; do
    base="$(basename -- "$dir")"
    tail="$base${tail:+/$tail}"
    parent="$(dirname -- "$dir")"
    [[ "$parent" == "$dir" ]] && break
    dir="$parent"
  done
  [[ -d "$dir" ]] || return 0
  GIT_ANCHOR="$(cd "$dir" 2>/dev/null && pwd -P || true)"
  [[ -z "$GIT_ANCHOR" ]] && return 0
  if [[ -n "$tail" ]]; then
    CANON_DIR="$GIT_ANCHOR/$tail"
  else
    CANON_DIR="$GIT_ANCHOR"
  fi
}

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
[[ "$tool_name" == "Write" ]] || exit 0

fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
[[ -z "$fp" ]] && exit 0

# 相対 file_path は git -C が hook の CWD 基準になり判定が壊れるので安全側で素通し。
[[ "$fp" = /* ]] || exit 0

case "$fp" in
*.md) ;;
*) exit 0 ;;
esac

# パス正規化: git --show-toplevel は canonical を返すが fp は非正規化でありうる
# (macOS の /tmp→/private/tmp 等)。dir を canonical 化し canonical_fp を以後の判定に使う。
# 最近接既存祖先まで遡れず canonical 化が総失敗した場合のみ安全側で素通し。
dir="$(dirname -- "$fp")"
base="$(basename -- "$fp")"
canonicalize_dir "$dir"
cdir="$CANON_DIR"
[[ -z "$cdir" ]] && exit 0
cfp="$cdir/$base"

# スコープ除外(いずれか該当で素通し)。canonical_fp で評価する:
#   - vault 自身 / 一時領域(macOS の /tmp 実体 /private/tmp・/var/folders 含む)
#   - */.claude/*: Claude 設定ディレクトリは意図的に全許可(確定方針)。live ~/.claude/**
#     と各リポの .claude/** の双方で skill/hook/agent/command 定義の .md を巻き込まない。
case "$cfp" in
"$HOME"/obsidian/brain/*) exit 0 ;;
/tmp/* | /private/tmp/* | /var/folders/*) exit 0 ;;
*/.claude/*) exit 0 ;;
esac

# 既存ファイルの上書きは常に許可(新規生成だけブロック)。
[[ -e "$cfp" ]] && exit 0

# git -C には実在祖先(GIT_ANCHOR)を渡す。cdir は未存在の新規サブディレクトリを
# 含みうるため git -C "$cdir" は fail する。
toplevel="$(git -C "$GIT_ANCHOR" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$toplevel" ]] && exit 0

# repo 相対パス(toplevel も --show-toplevel で canonical なので cfp と整合)。
rel="${cfp#"$toplevel"/}"

# chezmoi ソース除外: repo ルート直下の home/dot_* に限定(rel アンカー)。
# 任意リポの任意深さ /home/dot_ を素通しすると広すぎるため、repo ルートの home/ 配下
# (chezmoi ソースの実体)だけを除外する。dotfiles/cc-dotfiles の正当な新規 .md を誤爆しない。
case "$rel" in
home/dot_*) exit 0 ;;
esac

case "$base" in
README.md | CONTRIBUTING.md | CHANGELOG.md | LICENSE.md | CLAUDE.md | AGENTS.md | SECURITY.md) exit 0 ;;
esac

# docs/** と .github/** 配下は dev doc として通す(toplevel からの相対で判定)。
case "$rel" in
docs/* | .github/*) exit 0 ;;
esac

repo_key="$("$HOME/.claude/hooks/lib/resolve-repo-key.sh" "$GIT_ANCHOR" 2>/dev/null || true)"
: "${repo_key:=$(basename -- "$toplevel")}"

{
  echo "ブロック: リポ配下の新規ドキュメント生成は禁止です: $cfp"
  echo "作業ドキュメント(plan/report/findings 等)は外部脳へ書いてください:"
  echo "  ~/obsidian/brain/Tasks/${repo_key}/<トピック>.md"
  echo "(dev doc は README/CONTRIBUTING/CHANGELOG/LICENSE/CLAUDE/AGENTS/SECURITY, docs/**, .github/** のみ許可。既存 .md の編集は許可)"
} >&2
exit 2
