#!/usr/bin/env bash
# evolve-nudge-on-stop.sh — Stop hook
#
# ローカル進化(~/.claude-evolution)の区切りナッジ。セッションの切れ目で、skill 化に
# 値する学びの候補生成(/evolve)と、未処理候補のトリアージ(/evolve-gate)を Claude へ
# 中立に促す。生成するか/しないかの判断はフックに持たせず、文脈を持つ Claude に委ねる
# (selfcheck-on-stop.sh の自己チェックナッジと同じ分業)。
#
# 発火条件(どちらも満たさなければ無音素通り):
#   (a) 同 ctx に cs-injected-* フラグが存在(= このセッションでコード編集が起きた)
#   (b) candidates/ に未処理候補が滞留している
#   Stop はセッション終了時でなく応答完了ごとに発火するため、無条件だと最初の応答完了
#   (学びゼロ時点)でナッジを消費して空回りする。(a)(b) で「区切り」に寄せる。
#
# 1 ctx 1 回: evolve-nudged-${ctx} フラグ(flag-paths.sh が単一情報源)。ctx は
# transcript_path 基準(session_id は subagent と共有される dotfiles#62)。
# rearm-coding-standards.sh(clear|compact)がフラグを破棄して再武装する。
#
# 安全側設計(fail-open): jq 不在 / lib 不達 / ctx 不明 / 想定外はすべて exit 0 で
# 無音素通り。block 形式は Stop の正典 top-level {"decision":"block","reason":...}。
# stop_hook_active=true は無条件素通し(1 停止チェーン 1 回)。
set -euo pipefail

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$LIB" ) >/dev/null 2>&1 || exit 0
# shellcheck source=/dev/null
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0

active="$(hook_field '.stop_hook_active')"
[[ "$active" != "true" ]] || exit 0

source_hook_lib flag-paths.sh || exit 0
# apply 前後の版ずれ(古い flag-paths.sh に新関数が無い)は fail-open。
type evolve_nudged_flag >/dev/null 2>&1 || exit 0

ctx="$(hook_field '.transcript_path // .session_id')"
ctx="$(flag_ctx_key "$ctx" 2>/dev/null || true)"
[[ -n "$ctx" ]] || exit 0

# 1 ctx 1 回(既にナッジ済みなら素通り)。
[[ -f "$(evolve_nudged_flag "$ctx")" ]] && exit 0

# 発火条件 (a): このセッションでコード編集が起きたか(inject-coding-standards の
# 既注入フラグを編集発生のシグナルとして読む。キーは flag-paths.sh で完全一致)。
edited=0
shopt -s nullglob
cs_flags=("$(cs_injected_flag_prefix "$ctx")"*)
[[ ${#cs_flags[@]} -gt 0 ]] && edited=1

# 発火条件 (b): candidates/ の滞留候補数(skill はディレクトリ内 SKILL.md、agent は .md)。
EVOLVE_DIR="$HOME/.claude-evolution"
pending=0
cand_skills=("$EVOLVE_DIR"/candidates/skills/*/SKILL.md)
cand_agents=("$EVOLVE_DIR"/candidates/agents/*.md)
pending=$((${#cand_skills[@]} + ${#cand_agents[@]}))

[[ "$edited" -eq 1 || "$pending" -gt 0 ]] || exit 0

# 中立文: 「生成しろ」と書かない。学びが無ければそのまま停止してよいことを明示する。
reason="停止を検出した(ローカル進化の区切りナッジ・このセッションでは一度きり)。"
if [[ "$edited" -eq 1 ]]; then
  reason+="このセッションの作業に、skill 化に値する学び(繰り返された指摘・再利用可能な手順・落とし穴)があるか確認せよ。あれば /evolve で候補を生成せよ(候補は candidates/ 止まりで、人間が有効化するまで効力を持たない)。"
fi
if [[ "$pending" -gt 0 ]]; then
  reason+="未処理の候補(skill/agent)が ${pending} 件滞留している。都合がよければ /evolve-gate でトリアージを人間に提案せよ。"
fi
reason+="該当がなければ何もせずそのまま停止してよい(再度停止すればこのナッジは繰り返さない)。"

out="$(jq -n --arg reason "$reason" '{decision: "block", reason: $reason}' 2>/dev/null || true)"
[[ -n "$out" ]] || exit 0
printf '%s\n' "$out"
# mark は出力成功後(先に立てると jq 失敗時にフラグだけ残りナッジが欠落する)。
{ claude_flag_dir_ensure && touch "$(evolve_nudged_flag "$ctx")"; } 2>/dev/null || true
exit 0
