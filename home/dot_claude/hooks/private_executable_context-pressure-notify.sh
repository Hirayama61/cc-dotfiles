#!/usr/bin/env bash
# context-pressure-notify.sh — UserPromptSubmit hook
#
# コンテキスト使用率の 2 閾値通知と、圧縮直後の復帰注入を行う。使用率の供給源は
# statusline が書く usage.json(hook stdin には使用率が来ないため)。閾値は statusline
# 表示の used_percentage と同一の値 = 人間が画面で見る数字と機械の判断根拠を一致させる。
#
# 優先順:
#   1. compacted marker があれば復帰注入(PostCompact は additionalContext を返せない
#      仕様のため、postcompact-marker.sh が書いた marker をここで拾う 2 段構成が唯一経路)
#   2. 50% 以上: 最終通告(作業単位を閉じて compact-prep → 人間へ /compact 依頼)
#   3. 30% 以上: compact-prep 提案。前回通知から +5 ポイントごとに再通知
#      (1 回きりだと無視した瞬間に死ぬ通知になり、毎ターンはノイズ)
#
# 設計判断の正典: Decisions/cc-dotfiles/2026-07-22-コンテキスト逼迫対策をcompact正で設計
# 安全側設計: usage.json 不在 / stale(30 分超)/ 破損はすべて無言 exit 0(fail-open)。
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

inject() {
  jq -n --arg body "$1" '{
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: $body
    }
  }'
}

# 1. 圧縮直後の復帰注入
compacted="$(ctx_compacted_marker "$ctx")"
if [[ -f "$compacted" ]]; then
  state_file="$(ctx_state_file "$ctx")"
  decisions_file="$(ctx_decisions_file "$ctx")"
  NOTE="直前にコンテキスト圧縮が行われた。作業を再開する前に必ず次を行え: (1) state file ${state_file} を Read し、Active Plan / Session Decisions / Constraints / Worker Topology / Editing Files を現在状態として復元する。(2) 決定ログ ${decisions_file} を Read し、state file に載っていない人間の判断・指示がないか突合する。(3) 圧縮サマリーに書かれた next step は仮説として扱い、state file と決定ログを正とする。(4) plan mode が解除されていたら再突入を人間に確認する。"
  if inject "$NOTE"; then
    rm -f "$compacted" 2>/dev/null || true
  fi
  exit 0
fi

usage_file="$(ctx_usage_file "$ctx")"
[[ -r "$usage_file" ]] || exit 0

pct="$(jq -r '.pct // empty' "$usage_file" 2>/dev/null || true)"
updated_at="$(jq -r '.updated_at // empty' "$usage_file" 2>/dev/null || true)"
case "$pct" in "" | *[!0-9.]*) exit 0 ;; esac
case "$updated_at" in "" | *[!0-9]*) exit 0 ;; esac
now="$(date +%s)"
(( now - updated_at > 1800 )) && exit 0
pct_int="${pct%%.*}"
case "$pct_int" in "" | *[!0-9]*) exit 0 ;; esac

# 2. 最終通告(50%)
if (( pct_int >= 50 )); then
  inject "コンテキスト使用率が ${pct_int}% に達した(最終通告ライン)。このターンで現在の作業単位を閉じよ。新規の作業単位を開始してはならない。作業単位を閉じたら compact-prep skill を実行して state file を書き、人間に /compact の実行を依頼せよ。次のターン以降、編集系ツールはブロックされる。" || true
  exit 0
fi

# 3. 提案(30%、+5 ポイントごとに再通知)
if (( pct_int >= 30 )); then
  notified_file="$(ctx_notified_pct_file "$ctx")"
  notified="$(cat "$notified_file" 2>/dev/null || echo 0)"
  case "$notified" in "" | *[!0-9]*) notified=0 ;; esac
  if (( notified == 0 || pct_int - notified >= 5 )); then
    if inject "コンテキスト使用率が ${pct_int}% を超えた(提案ライン)。判断力が保たれている今のうちに、作業の区切りで compact-prep skill を実行して state file を書き、人間に /compact を提案せよ。大量出力を伴う調査はサブエージェントへの委譲を検討せよ。50% に達すると編集がブロックされる。"; then
      claude_ctx_cache_ensure "$ctx" && printf '%s' "$pct_int" > "$notified_file" 2>/dev/null || true
    fi
  fi
fi

exit 0
