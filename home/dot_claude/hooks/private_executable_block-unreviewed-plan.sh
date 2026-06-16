#!/usr/bin/env bash
# PreToolUse(ExitPlanMode): 設計レビューゲート Gate 1(参謀ゲート Phase 4)。
# design-reviewed フラグ(branch / ctx / fresh pending)が無ければ Plan の確定を
# ブロックし、/design-review の実行を誘導する。
#
# trivial-override は認めない(Plan を立てた時点で「軽微」ではない=計画仕様。
# 軽微タスクの脱出口は Gate 2 側にある)。
# 判定核は design-gate.sh、キーは flag-paths.sh が単一情報源。
# 除外(repo 外 / vault / 一時領域)も design-gate.sh の判定に従う。
#
# 安全側設計: jq 無し / lib 不達・破損 / repo 不明なら exit 0(通す)。
set -euo pipefail

# git 判定核を環境変数注入で狂わされないよう無効化(block-main-clone-edit と同作法)。
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$LIB" ) >/dev/null 2>&1 || exit 0
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0
# 空入力(stdin 無し)は判定材料が無く、cwd 未指定で $PWD フォールバックすると無関係 repo の
# design-gate を巻き込んで誤ブロックする。他 hook の異常系と同じく fail-open で素通す。
[[ -z "${HOOK_INPUT:-}" ]] && exit 0
sid="$(hook_session_id)"
# 破損 JSON 等で cwd 抽出不能な時に $PWD へフォールバックすると、hook 実行 dir の
# 無関係 repo の design-gate を巻き込んで誤ブロックする(空 stdin ガードは空入力のみ)。
cwd="$(hook_cwd)"
[[ -z "$cwd" ]] && exit 0
# 相対 cwd は hook 実行ディレクトリ依存で別 repo を見に行くため判定しない
# (Gate 2 の相対 file_path 素通しと同じ fail-open)。
[[ "$cwd" = /* ]] || exit 0
cwd="$(cd "$cwd" 2>/dev/null && pwd -P || printf '%s' "$cwd")"

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

design_gate_exempt_dir "$cwd" && exit 0

REPO_RESOLVER="$HOME/.claude/hooks/lib/resolve-repo-key.sh"
repo_key=""
[[ -x "$REPO_RESOLVER" ]] && repo_key="$("$REPO_RESOLVER" "$cwd" 2>/dev/null || true)"
[[ -z "$repo_key" ]] && exit 0

branch="$(git -C "$cwd" branch --show-current 2>/dev/null || echo "")"

if design_gate_pass "$repo_key" "$sid" "$branch" 0; then
  exit 0
fi

echo "ブロック: 設計レビュー未通過(repo=${repo_key})。Plan を確定する前に /design-review を実行し、人間トリアージ通過で design-reviewed フラグを得ること。レビュー通過後にもう一度 ExitPlanMode を実行すれば通る。" >&2
exit 2
