#!/usr/bin/env bash
# PreToolUse(Edit|Write|MultiEdit|NotebookEdit): 設計レビューゲート Gate 2
# (参謀ゲート Phase 4。Plan-skip 穴の閉鎖)。
#
# コード repo への mutation が、design-reviewed フラグ(branch / ctx / fresh pending)
# も trivial-override(ctx / fresh pending)も無いなら、編集はブロックせず設計レビュー
# 未通過の警告を additionalContext で注入する(2026-07-11 監査トリアージ 争点2 で
# ブロックから警告へ格下げ。理由は commit / Decisions)。終端の砦は push 前の
# self-review ゲートが担う。警告は同一コンテキストで 1 回だけ出す(design-gate-warned
# フラグ。rearm-coding-standards が clear|compact で再武装)。
# mutation を契機にすることで read-only の調査・Agent 調査委譲は素通り(research/実装の
# 意味判定をフックから追い出す=計画仕様)。警告の抑制口は (a) Plan → /design-review、
# (b) 人間の承認を得た理由付き trivial-override(理由をフラグ内容に記録・監査可能)。
#
# 判定核は design-gate.sh、キーは flag-paths.sh が単一情報源。Gate 1
# (block-unreviewed-plan)と design-gate.sh / フラグ機構の共有部分は不変。
# 除外 = git repo 外 / ~/obsidian 配下 / repo root が一時領域(/tmp・/private/tmp・
# ~/.claude/jobs)。コード repo だけを守る(判断②)。
#
# 安全側設計: 警告注入の失敗で編集を止めない。jq 無し / lib 不達・破損 / 相対パス /
# repo 不明はすべて exit 0(無音で通す)。PreToolUse だが exit 2 は一切返さない。
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

# 未通過 = 警告を注入して編集は通す。同一 ctx × 同一 repo へは 1 回だけ(design-gate-warned
# フラグ。キーは ctx--repo_key)。ctx は capture-decision と同じ transcript_path 基準
# (session_id は subagent と共有される)。flag-paths.sh 不達 / 版ずれ / ctx 不明は ctx 空の
# まま = 毎編集で警告へ倒す(警告欠落より毎回警告を選ぶ。抑制はベストエフォート)。
# 抑制判定は regular file のみ(-f は symlink を辿るため、予測可能パスへの symlink 設置で
# 警告を握り潰される。design-gate.sh の読取側硬化 _design_gate_flag_ok と対称)。
ctx="$(hook_field '.transcript_path // .session_id')"
ctx="$(flag_ctx_key "$ctx" 2>/dev/null || true)"
if [[ -n "$ctx" ]] && type design_gate_warned_flag >/dev/null 2>&1; then
  wflag="$(design_gate_warned_flag "$ctx" "$repo_key")"
  [[ -f "$wflag" && ! -L "$wflag" ]] && exit 0
fi

warn_body="$(cat <<EOF
[設計レビューゲート Gate 2 / 警告のみ] 設計レビュー未通過のコード repo(${repo_key})を編集した。この編集はブロックしていない(2026-07-11 監査トリアージ 争点2 で警告化。終端の砦は push 前の self-review ゲート)。まとまった変更・新規実装なら、手を止めて Plan を立て /design-review を通すのが本則。この警告はこのコンテキストで 1 回だけ出す。今後の警告も不要な軽微変更なら、人間の明示承認を得た理由付き override を立ててよい(理由はフラグ内容として監査可能):
    "\$HOME/.claude/hooks/lib/flag-paths.sh" dir-ensure
    printf '%s\n' '<人間が承認した理由>' > "\$("\$HOME/.claude/hooks/lib/flag-paths.sh" trivial-override-pending '${repo_key}')"
EOF
)"

printf '%s' "$warn_body" |
  jq -Rs '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:.}}' 2>/dev/null || exit 0

# mark は出力成功後(出力前だと jq 失敗時にフラグだけ残り警告が欠落する)。書込前に symlink を
# 弾く(touch が symlink を辿って別ファイルの mtime を更新するのを防ぐ。design-gate.sh の
# 書込側硬化と対称)。
if [[ -n "$ctx" ]] && type design_gate_warned_flag >/dev/null 2>&1; then
  wflag="$(design_gate_warned_flag "$ctx" "$repo_key")"
  [[ -L "$wflag" ]] || { claude_flag_dir_ensure && touch "$wflag"; } 2>/dev/null || true
fi
exit 0
