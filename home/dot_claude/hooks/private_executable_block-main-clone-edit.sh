#!/usr/bin/env bash
# block-main-clone-edit.sh — PreToolUse(Edit|Write|MultiEdit)
#
# main clone(~/ghq/...)配下のファイル編集をブロックし、wt.sh で
# ~/worktrees/... に worktree を作ってそこで編集するよう促す。
# 狙い: 複数ジョブが main clone 共有ツリーで混線するのを防ぐ(決定 B)。
# 人間の手編集は hook を通らないので素通り(= main は人間用 / Claude は worktree)。
#
# 安全側設計: jq 不在 / file_path 空 / 相対パス / canonical 化失敗 はすべて exit 0。
# scope は ~/ghq/ 配下に厳密限定(~/obsidian/brain 等の非開発 repo を巻き込まない)。
# ~/worktrees/ は別ツリーなので接頭辞非一致で自動的に通る。
#
# pre-edit-guard.sh の */home/dot_* 除外は意図的に持ち込まない:
#   pre-edit-guard は「deploy 実体を編集させず chezmoi ソースへ誘導」が目的なので
#   chezmoi ソース(.../home/dot_*)を許可するが、本 hook は「どの worktree で編集
#   するか」を強制するのが目的。main clone の chezmoi ソース(~/ghq/.../home/dot_*)を
#   許可してしまうと決定 B(ソース編集も worktree でやれ)に反するため除外しない。
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
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

# main clone スコープ判定: $HOME/ghq/ 配下のみブロック。
# (~/worktrees/ は別ツリー → 非一致で通る。~/obsidian/brain も非一致で通る。)
case "$cfp" in
"$HOME"/ghq/*)
  {
    echo "ブロック: main clone(~/ghq/...)配下のファイルは Claude から編集できません: $cfp"
    echo "main clone はリモートコードの集約本体です(read/集約専用)。編集は worktree で行ってください:"
    echo "  cd \"\$(~/ghq/github.com/Hirayama61/dotfiles/bin/wt.sh <branch>)\""
    echo "  → ~/worktrees/<host>/<owner>/<repo>/<branch> が作られ、その中で編集すればこの hook は通ります。"
    echo "(人間の手編集は hook 対象外なので素通りします。)"
  } >&2
  exit 2
  ;;
esac

exit 0
