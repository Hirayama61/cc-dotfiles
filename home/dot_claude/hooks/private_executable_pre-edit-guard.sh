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

# 絶対パスの `.`/`..` セグメントを純シェルで論理正規化する(bash 3.2 互換・symlink 非解決)。
# `/` で分割し位置パラメータをスタックに使う。`.`/空は捨て、`..` は1つ pop。ルートを越える
# `..`(`/..`)は安全側で捨てる(= `/`)。block-repo-doc / block-main-clone-edit と同一実装。
_normalize_path() {
  local p="$1"
  case "$p" in /*) ;; *) printf '%s' "$p"; return 0 ;; esac
  local oldifs="$IFS" seg _noglob=0
  local -a stack=()
  IFS='/'
  case $- in *f*) _noglob=1 ;; esac
  set -f
  # IFS='/' で意図的に単語分割してセグメント化する(quote すると分割されない)。set -f は
  # パス内の glob メタ文字(* ? [ ])が分割と同時に展開され正規化結果が cwd 依存になるのを
  # 防ぐ(Next.js の [id] 等。SEC-2)。元の glob 状態を保存して復元する。
  # shellcheck disable=SC2086
  set -- $p
  [[ $_noglob -eq 0 ]] && set +f
  IFS="$oldifs"
  for seg in "$@"; do
    case "$seg" in
    '' | .) ;;
    ..) [[ ${#stack[@]} -gt 0 ]] && unset 'stack[${#stack[@]}-1]' ;;
    *) stack[${#stack[@]}]="$seg" ;;
    esac
  done
  [[ ${#stack[@]} -eq 0 ]] && { printf '/'; return 0; }
  local out=""
  for seg in "${stack[@]}"; do out="$out/$seg"; done
  printf '%s' "$out"
}

# 親 dir が未存在でも canonical 化する。Write は中間ディレクトリを自動生成するため、
# 新規サブディレクトリ(home/dot_newdir/ 等)への新規ファイルでも最近接既存祖先まで遡って
# 解決し未存在 tail を再付与する。これをしないと `cd "$guard_dir"` が失敗して guard_anchor が
# 空になり home/dot_* 除外をすり抜け、新規 chezmoi ソースを deploy 実体扱いで誤 over-block する
# (F-005。block-repo-doc / block-main-clone-edit の canonicalize_dir と同型)。
# CANON_DIR=正規化 dir(rel 算出用)/ GIT_ANCHOR=git -C 用の実在祖先(未存在 dir を git -C に
# 渡すと fail するため分離)。総失敗時は両方空。
CANON_DIR=""
GIT_ANCHOR=""
canonicalize_dir() {
  local dir tail="" base parent
  dir="$(_normalize_path "$1")"
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
# rel は git --show-toplevel(canonical)からの相対なので canonical_fp で算出する。git -C には
# 実在祖先(GIT_ANCHOR)を、rel には未存在 tail まで含む CANON_DIR を使う。
# git 外 / 非 repo-root の home/dot_ は除外せず下の保護判定へ落とす(deploy 実体を取りこぼさない)。
guard_dir="$(dirname -- "$file_path")"
canonicalize_dir "$guard_dir"
if [[ -n "$CANON_DIR" ]]; then
  toplevel="$(git -C "$GIT_ANCHOR" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$toplevel" ]]; then
    rel="${CANON_DIR}/$(basename -- "$file_path")"
    rel="${rel#"$toplevel"/}"
    case "$rel" in
    home/dot_*) exit 0 ;;
    esac
  fi
fi

# 保護判定も canonical 化したフルパスで行う(生 file_path だと .claude/x/../hooks/evil.sh の
# ような `..` 経由で保護をすり抜ける。SEC-3)。canonicalize_dir 失敗時のみ生 file_path に退避。
canonical_fp="$file_path"
[[ -n "$CANON_DIR" ]] && canonical_fp="${CANON_DIR}/$(basename -- "$file_path")"
case "$canonical_fp" in
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
