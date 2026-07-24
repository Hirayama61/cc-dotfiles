#!/usr/bin/env bash
# postcompact-marker.sh — PostCompact hook: 圧縮完了の marker と通知系フラグの再武装
#
# PostCompact は additionalContext を返せない(公式仕様)ため、ここでは compacted
# marker を書くだけにし、圧縮直後の復帰指示は次の UserPromptSubmit で
# context-pressure-notify.sh が注入する(2 段構成が唯一経路)。
#
# あわせて閾値通知系のフラグを再武装する: 圧縮後は使用率が下がるので、
# notified-pct(30% 提案の再通知基準)/ grace-turn(50% 猶予)/ precompact-blocked
# (素 compact の 1 回許可)を破棄し、新しい文脈で最初から判定させる。
# usage.json も消す: 残すと statusline が圧縮後の低い値を書くまでの間、gate/notify が
# 圧縮前の 50% 超の値で再発火する(不在なら fail-open 素通しで、すぐ新値が書かれる)。
# state file と decisions.jsonl は消さない(復帰注入の読み戻し先 + compact 跨ぎの照合元)。
set -euo pipefail

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$LIB" ) >/dev/null 2>&1 || exit 0
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0
source_hook_lib context-paths.sh || exit 0
type claude_ctx_key >/dev/null 2>&1 || exit 0

ctx="$(claude_ctx_key "$(hook_field '.transcript_path')")"
[[ -z "$ctx" ]] && exit 0

umask 077
claude_ctx_cache_ensure "$ctx" || exit 0
touch "$(ctx_compacted_marker "$ctx")" 2>/dev/null || true
rm -f "$(ctx_notified_pct_file "$ctx")" "$(ctx_grace_turn_file "$ctx")" \
  "$(ctx_precompact_blocked_marker "$ctx")" "$(ctx_usage_file "$ctx")" 2>/dev/null || true

exit 0
