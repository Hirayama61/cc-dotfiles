#!/usr/bin/env bash
# block-main-clone-edit.sh — PreToolUse(Edit|Write|MultiEdit)
#
# main clone(~/ghq/ 配下の*プライマリ作業ツリー*)でのファイル編集をブロックし、
# worktree を作ってそこで編集するよう促す。
# 狙い: 複数ジョブが main clone 共有ツリーで混線するのを防ぐ(決定 B)。
# 人間の手編集は hook を通らないので素通り(= main は人間用 / Claude は worktree)。
#
# 安全側設計: jq 不在 / file_path 空 / 相対パス / canonical 化失敗 はすべて exit 0。
# scope は ~/ghq/ 配下に限定(~/obsidian/brain 等の非開発 repo を巻き込まない)。
#
# linked worktree は場所を問わず許可する。harness の isolation:"worktree" は worktree を
# ~/ghq/<repo>/.claude/worktrees/agent-* (= ~/ghq 配下)に作るため、path 接頭辞だけでは
# main clone 本体と区別できない。そこで git で「プライマリ作業ツリー(--git-dir == --git-common-dir)
# か否か」で判定する: プライマリ = main clone 本体 → block / linked(wt.sh の ~/worktrees も
# harness の .claude/worktrees/agent-* も --git-dir != --git-common-dir)→ 許可。
#
# pre-edit-guard.sh の */home/dot_* 除外は意図的に持ち込まない:
#   pre-edit-guard は「deploy 実体を編集させず chezmoi ソースへ誘導」が目的なので
#   chezmoi ソース(.../home/dot_*)を許可するが、本 hook は「どの worktree で編集
#   するか」を強制するのが目的。main clone の chezmoi ソース(~/ghq/.../home/dot_*)を
#   許可してしまうと決定 B(ソース編集も worktree でやれ)に反するため除外しない。
set -euo pipefail

# git 判定の核(--git-dir / --git-common-dir)を環境変数注入で狂わされないよう無効化する。
# 混線したシェルや export が GIT_DIR 等を持ち込むと、main clone 本体の編集を linked worktree と
# 誤判定してブロックをすり抜けられる(bgIsolation:none 下で本 hook が混線防止の最後の砦になるため)。
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY

# 絶対パスの `.`/`..` セグメントを純シェルで論理正規化する(bash 3.2 互換・symlink 非解決)。
# 未存在の中間 dir + `..` は cd+pwd -P で物理化できず tail に `..` が残り、後段の接頭辞/scope
# 判定をすり抜けうる(F-001。block-repo-doc と同型)。canonical 化前に `..` を畳んで防ぐ。
# `/` で分割し位置パラメータをスタックに使う。`.`/空は捨て、`..` は1つ pop。ルートを越える
# `..`(`/..`)は安全側で捨てる(= `/`)。block-repo-doc / pre-edit-guard と同一実装。
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
# 新規サブディレクトリへの新規ファイルを最近接既存祖先まで遡って解決し未存在 tail を再付与する。
# CANON_DIR=正規化 dir(接頭辞判定用)/ GIT_ANCHOR=git -C 用の実在祖先(未存在 dir を
# git -C に渡すと fail するため分離)。総失敗時は両方空。
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

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
[[ -z "$fp" ]] && exit 0

# 相対パスは hook の CWD 基準になり判定が壊れるので安全側で素通し(block-repo-doc 同様)。
[[ "$fp" = /* ]] || exit 0

# canonical 化(macOS の symlink / /tmp→/private/tmp 等で接頭辞判定が外れるのを防ぐ)。
# 最近接既存祖先まで遡れず canonical 化が総失敗した場合のみ安全側で素通し。
dir="$(dirname -- "$fp")"
base="$(basename -- "$fp")"
canonicalize_dir "$dir"
cdir="$CANON_DIR"
[[ -z "$cdir" ]] && exit 0
cfp="$cdir/$base"

# scope 判定: $HOME/ghq/ 配下のみ対象(~/worktrees/・~/obsidian/brain は非一致で素通り)。
case "$cfp" in
"$HOME"/ghq/*) ;;
*) exit 0 ;;
esac

# ~/ghq 配下でも、ブロックするのは *プライマリ作業ツリー(main clone 本体)* のみ。
# linked worktree(--git-dir != --git-common-dir)は per-branch 隔離されているので許可する。
# 非 git ディレクトリ(main clone ではない)も許可。比較は cd+pwd -P で絶対化し相対表記/version 差を避ける。
# --is-inside-work-tree は work-tree 外(例 .git/ 配下)でも exit 0 + 出力 "false" を返すので
# exit code でなく出力 == true を見る。git-dir/common-dir が空だと cd "" で cwd 据え置き →
# 誤一致(誤ブロック)になるため空を明示的に弾く。
# git 操作には実在祖先(GIT_ANCHOR)を使う。cdir は未存在の新規サブディレクトリを含みうるため
# (Write が中間 dir を後で生成する)git -C / cd "$cdir" が fail する。git-dir/common-dir の
# 関係は同一 work-tree 内なら祖先でも同じなので判定は変わらない。
[[ "$(git -C "$GIT_ANCHOR" rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]] || exit 0
rel_gd="$(git -C "$GIT_ANCHOR" rev-parse --git-dir 2>/dev/null || true)"
rel_gcd="$(git -C "$GIT_ANCHOR" rev-parse --git-common-dir 2>/dev/null || true)"
[[ -z "$rel_gd" || -z "$rel_gcd" ]] && exit 0
gd="$(cd "$GIT_ANCHOR" && cd "$rel_gd" 2>/dev/null && pwd -P || true)"
gcd="$(cd "$GIT_ANCHOR" && cd "$rel_gcd" 2>/dev/null && pwd -P || true)"
[[ -z "$gd" || -z "$gcd" || "$gd" != "$gcd" ]] && exit 0

{
  echo "ブロック: main clone(~/ghq/... のプライマリ作業ツリー)のファイルは Claude から編集できません: $cfp"
  echo "main clone はリモートコードの集約本体です(read/集約専用)。編集は worktree で行ってください:"
  echo "  cd \"\$(~/ghq/github.com/Hirayama61/dotfiles/bin/wt.sh <branch>)\""
  echo "  → ~/worktrees/<host>/<owner>/<repo>/<branch> が作られ、その中で編集すればこの hook は通ります。"
  echo "(人間の手編集は hook 対象外なので素通りします。)"
} >&2
exit 2
