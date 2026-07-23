#!/usr/bin/env bash
# precompact-gate.sh — PreCompact hook: state file なしの素の compact を止める
#
# 手動 /compact の前に compact-prep(state file の書き出し)を強制する。state file が
# 無い / 古い / 構造が壊れたまま圧縮すると、判断構造(採用・却下・却下理由・現在位置)が
# 要約から落ちて復元不能になるため。
#
# trigger による分岐(公式 docs 確認済みの外部仕様。2026-07-22):
#   - "manual": 検査対象。block すると /compact がスキップされ会話は続く(無害)
#   - "auto": 無条件素通し。autoCompactEnabled: false の運用下で auto が来るのは
#     API のコンテキスト上限エラー復帰用であり、block すると当該リクエストが失敗する
#   - 空(想定外入力): 素通し(fail-open)
#
# block は 1 ctx 1 回まで(precompact-blocked marker)。2 回目は state file が
# 無くても通す = 人間が意図的に素の compact を選んだと解釈する(恒久ブロックにしない)。
# 構造検証は compact-prep skill の validate-state.sh を借用(不在なら mtime のみに縮退)。
set -euo pipefail

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$LIB" ) >/dev/null 2>&1 || exit 0
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0
source_hook_lib context-paths.sh || exit 0
type claude_ctx_key >/dev/null 2>&1 || exit 0

trigger="$(hook_field '.trigger')"
[[ "$trigger" == "manual" ]] || exit 0

ctx="$(claude_ctx_key "$(hook_field '.transcript_path')")"
[[ -z "$ctx" ]] && exit 0

blocked_marker="$(ctx_precompact_blocked_marker "$ctx")"
[[ -f "$blocked_marker" ]] && exit 0

state_file="$(ctx_state_file "$ctx")"
state_ok=""
if [[ -f "$state_file" ]]; then
  mtime="$(stat -f '%m' "$state_file" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  case "$mtime" in "" | *[!0-9]*) mtime=0 ;; esac
  if (( now - mtime <= 900 )); then
    validator="$HOME/.claude/skills/compact-prep/scripts/validate-state.sh"
    if [[ -r "$validator" ]]; then
      bash "$validator" "$state_file" >/dev/null 2>&1 && state_ok=1
    else
      state_ok=1
    fi
  fi
fi
[[ -n "$state_ok" ]] && exit 0

claude_ctx_cache_ensure "$ctx" && touch "$blocked_marker" 2>/dev/null || true
echo "ブロック: state file(${state_file})が無い・古い・または構造が不完全なまま /compact しようとした。先に compact-prep skill(/compact-prep)を実行して判断構造を退避してから /compact をやり直すこと。それでも素の compact を行いたい場合は、もう一度 /compact を実行すれば通る(このブロックは 1 回のみ)。" >&2
exit 2
