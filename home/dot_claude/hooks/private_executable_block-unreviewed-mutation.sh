#!/usr/bin/env bash
# PreToolUse(Edit|Write|MultiEdit|NotebookEdit): 設計レビューゲート Gate 2
# (参謀ゲート Phase 4。Plan-skip 穴の閉鎖)。
#
# コード repo への mutation を、design-reviewed フラグ(branch / ctx / fresh pending)
# も trivial-override(ctx / fresh pending)も無い状態でブロックする。mutation を
# 契機にすることで read-only の調査・Agent 調査委譲は素通り(research/実装の意味判定を
# フックから追い出す=計画仕様)。脱出口は (a) Plan → /design-review、
# (b) 人間の承認を得た理由付き trivial-override(理由をフラグ内容に記録・監査可能)。
#
# 判定核は design-gate.sh、キーは flag-paths.sh が単一情報源。
# 除外 = git repo 外 / ~/obsidian 配下 / repo root が一時領域(/tmp・/private/tmp・
# ~/.claude/jobs)。コード repo だけを守る(判断②)。
#
# 安全側設計: jq 無し / lib 不達・破損 / 相対パス / repo 不明なら exit 0(通す)。
set -euo pipefail

# git 判定核を環境変数注入で狂わされないよう無効化(block-main-clone-edit と同作法)。
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$LIB" ) >/dev/null 2>&1 || exit 0
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0
sid="$(hook_session_id)"
fp="$(hook_field '.tool_input.file_path // .tool_input.notebook_path')"
# 相対パスは hook の cwd 依存で壊れるため絶対パスのときだけ判定(inject と同作法)。
[[ "$fp" = /* ]] || exit 0

FLAG_LIB="$HOME/.claude/hooks/lib/flag-paths.sh"
[[ -r "$FLAG_LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$FLAG_LIB" ) >/dev/null 2>&1 || exit 0
# shellcheck source=/dev/null
. "$FLAG_LIB" 2>/dev/null || exit 0
GATE_LIB="$HOME/.claude/hooks/lib/design-gate.sh"
[[ -r "$GATE_LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$GATE_LIB" ) >/dev/null 2>&1 || exit 0
# shellcheck source=/dev/null
. "$GATE_LIB" 2>/dev/null || exit 0
# is_protected_branch(branch 定着用)。読めなくても判定自体は成立するため任意。
BASE_LIB="$HOME/.claude/hooks/lib/resolve-base-ref.sh"
# shellcheck source=/dev/null
if [[ -r "$BASE_LIB" ]] && ( . "$BASE_LIB" ) >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$BASE_LIB" 2>/dev/null || true
fi

# Write は親ディレクトリを自動作成するため、未作成ディレクトリ配下への書込で
# dirname の cd が失敗すると「repo 不明 → 素通し」に化ける(新規モジュールを
# 切って実装を始める典型場面のバイパス)。実在する最近接祖先まで遡って判定する。
probe="$(dirname -- "$fp")"
while [[ -n "$probe" && "$probe" != "/" && ! -d "$probe" ]]; do
  probe="$(dirname -- "$probe")"
done
dir="$(cd "$probe" 2>/dev/null && pwd -P || true)"
[[ -z "$dir" ]] && dir="$probe"
design_gate_exempt_dir "$dir" && exit 0

root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$root" ]] && exit 0

REPO_RESOLVER="$HOME/.claude/hooks/lib/resolve-repo-key.sh"
repo_key=""
[[ -x "$REPO_RESOLVER" ]] && repo_key="$("$REPO_RESOLVER" "$root" 2>/dev/null || true)"
[[ -z "$repo_key" ]] && exit 0

branch="$(git -C "$root" branch --show-current 2>/dev/null || echo "")"

if design_gate_pass "$repo_key" "$sid" "$branch" 1; then
  exit 0
fi

cat >&2 <<EOF
ブロック: 設計レビューも trivial-override も無いコード repo(${repo_key})への編集。人間に確認して次のどちらかを取ること:
(a) Plan を立てて /design-review を通す(設計レビューゲートの本則)。
(b) 軽微な変更なら、人間の明示承認を得た上で理由付き override を立てる:
    "\$HOME/.claude/hooks/lib/flag-paths.sh" dir-ensure
    printf '%s\n' '<人間が承認した理由>' > "\$("\$HOME/.claude/hooks/lib/flag-paths.sh" trivial-override-pending '${repo_key}')"
    (次の編集時に自セッションへ取り込まれて解除。理由が空だと通らない。フラグ内容として監査可能)
EOF
exit 2
