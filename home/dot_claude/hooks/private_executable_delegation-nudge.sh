#!/usr/bin/env bash
# delegation-nudge.sh — PostToolUse(Grep|Glob|Agent) に登録。
#
# リポ内探索(Grep/Glob)が積み重なると、メインのコンテキストが探索出力で圧迫される。
# 探索ツールの ctx 累計が閾値に達したら、委譲(scout / researcher / delegate の出し分け)を
# additionalContext で促す。Agent ツール使用でカウンタをリセットする(委譲が起きたら黙る)。
#
# カウント対象は Grep / Glob のみ。Read は数えない(編集対象の Read は委譲不可の中核作業)。
# 「連続」の厳密判定はイベント可視性の制約上せず、ctx 累計 + Agent 使用でリセットの意味論。
# Agent ツールの matcher 名は "Agent"(spike S-3 確定。Task ではない)。
#
# 並行安全 / 1 ctx 1 回 / subagent 抑制 / fail-open は stuck-nudge.sh と同一機構(lib 共有):
#   - カウントは flag-paths のマーカーファイル数え上げ(mktemp で一意ファイルを atomic 作成、
#     数 = ファイル数)で数値 RMW のロストアップデートを構造的に避ける(F-002)。
#   - ナッジ発火は delegation_nudged_flag を mkdir で atomic に claim した最初の1回だけ。
#   - agent_id があれば(subagent 発。spike S-2)即 exit 0。
#   - rearm-coding-standards.sh(clear|compact)がカウンタ・claim を破棄して再武装する。
#   - jq 不在 / lib 不達・破損 / ctx 不明 / state 書込不能 / 想定外は exit 0 で無音素通り。
#
# 破棄容易性: settings.json.tmpl の PostToolUse(Grep|Glob|Agent)ブロックを外せば無効化できる。
set -euo pipefail

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$LIB" ) >/dev/null 2>&1 || exit 0
# shellcheck source=/dev/null
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0

# subagent 内の探索は数えない(agent_id はメイン発の入力に無い。spike S-2)。
[[ -n "$(hook_field '.agent_id')" ]] && exit 0

source_hook_lib flag-paths.sh || exit 0
# 版ずれ(古い flag-paths.sh に新関数が無い)は fail-open。
type delegation_count_dir >/dev/null 2>&1 || exit 0

ctx="$(hook_field '.transcript_path // .session_id')"
ctx="$(flag_ctx_key "$ctx" 2>/dev/null || true)"
[[ -n "$ctx" ]] || exit 0
[[ "$ctx" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0

count_dir="$(delegation_count_dir "$ctx")"
tool="$(hook_tool_name)"

case "$tool" in
Agent)
  # 委譲が起きた: 累計をリセット(claim は 1 ctx 1 回のまま維持する)。
  flag_counter_reset "$count_dir"
  exit 0
  ;;
Grep | Glob) ;;
*) exit 0 ;;
esac

# state dir を用意してからカウント(書込不能なら fail-open)。
claude_flag_dir_ensure 2>/dev/null || exit 0
n="$(flag_counter_bump "$count_dir")"

THRESHOLD=5
[[ "$n" -ge "$THRESHOLD" ]] || exit 0

# 1 ctx 1 回: mkdir claim を atomic に取れた最初の1回だけナッジ。
claim="$(delegation_nudged_flag "$ctx")"
mkdir "$claim" 2>/dev/null || exit 0

NOTE="リポ内の探索(Grep/Glob)が積み重なっている(このセッションで一度きりの通知)。大量の探索・ログ漁り・長大ファイル読みはメインのコンテキストを圧迫する。委譲を検討せよ — リポ内探索・ログ漁りは scout(haiku)、外部ライブラリ・API・公式仕様の調査は researcher(sonnet)、判断・実装を伴う作業は delegate。編集対象の Read など委譲不可の中核作業はこの限りでない。"

jq -n --arg body "$NOTE" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $body
  }
}' || exit 0

exit 0
