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
# 誤判定してブロックをすり抜けられる(bgIsolation 隔離が効かない経路でも本 hook が混線防止の最後の砦になるため)。
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0
fp="$(hook_file_path)"
[[ -z "$fp" ]] && exit 0

# 相対パスは hook の CWD 基準になり判定が壊れるので安全側で素通し(block-repo-doc 同様)。
[[ "$fp" = /* ]] || exit 0

# canonical 化(macOS の symlink / /tmp→/private/tmp 等で接頭辞判定が外れるのを防ぐ)。
# 親 dir が未存在等で canonical 化できなければ安全側で素通し。
dir="$(dirname -- "$fp")"
base="$(basename -- "$fp")"
cdir="$(cd "$dir" 2>/dev/null && pwd -P || true)"
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
[[ "$(git -C "$cdir" rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]] || exit 0
rel_gd="$(git -C "$cdir" rev-parse --git-dir 2>/dev/null || true)"
rel_gcd="$(git -C "$cdir" rev-parse --git-common-dir 2>/dev/null || true)"
[[ -z "$rel_gd" || -z "$rel_gcd" ]] && exit 0
gd="$(cd "$cdir" && cd "$rel_gd" 2>/dev/null && pwd -P || true)"
gcd="$(cd "$cdir" && cd "$rel_gcd" 2>/dev/null && pwd -P || true)"
[[ -z "$gd" || -z "$gcd" || "$gd" != "$gcd" ]] && exit 0

{
  echo "ブロック: main clone(~/ghq/... のプライマリ作業ツリー)のファイルは Claude から編集できません: $cfp"
  echo "main clone はリモートコードの集約本体です(read/集約専用)。編集は worktree で行ってください:"
  echo "  cd \"\$(~/ghq/github.com/Hirayama61/dotfiles/bin/wt.sh <branch>)\""
  echo "  → ~/worktrees/<host>/<owner>/<repo>/<branch> が作られ、その中で編集すればこの hook は通ります。"
  echo "(人間の手編集は hook 対象外なので素通りします。)"
} >&2
exit 2
