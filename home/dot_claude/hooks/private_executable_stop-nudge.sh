#!/usr/bin/env bash
# stop-nudge.sh — Stop hook: 停止時ナッジの単一入口
#
# 停止しようとした Claude へ、独立した 2 つの条件で介入する:
#   - 未完タスクが残ったままの停止(ファントムツール呼び出しからの復帰)
#   - コンテキスト使用率 30% 以上で state file が古いまま(compact-prep の自動実行)
#
# 両方成立したら 1 つの block の reason に 2 文を連結する。reason は 1 本の文字列で
# 2 文を並べられるため、片方を捨てるのは制約ではなく選択になる。捨てると、逼迫時の
# 停止では復帰チェックが一度も出ないまま停止できてしまう。
#
# 設計上の前提と限界:
#   - block 形式は Stop の正典 top-level {"decision":"block","reason":...}
#     (ralph-loop stop-hook.sh / hook-development advanced.md 準拠)。PreToolUse 系の
#     hookSpecificOutput.decision は Stop では効かない。
#   - stop_hook_active=true なら無条件素通し。1停止チェーンで1回しか block しないため
#     「同一条件8連続 block の強制停止」には構造的に到達しない。
#   - タスクは ~/.claude/tasks/<session_id>/ に session_id 単位で分離保存される。よって
#     別セッションの滞留タスクは波及しない。session_id は subagent と共有されうる
#     (dotfiles#62)が、本フックは Stop(=メイン停止)だけに登録し SubagentStop には
#     載せない。混入しても 1停止1回 + Claude の自己チェックで影響は有界。
#   - 打ち止め(stop-nudged-turn)は compact-prep 側にだけ掛ける。compact-prep を完了
#     できない状況(plan mode 等)で毎停止の介入にしないため。タスク側は
#     stop_hook_active で既に有界なので追加の打ち止めは要らない。
#
# 安全側設計(fail-open): jq 不在 / session_id 不明 or 不正形式 / tasks 不在 / 想定外は
#   すべて exit 0 で無音素通り。破損 json はそのファイルだけスキップして残りを評価する。
#   context-paths.sh を取り込めない・ctx 不明・usage.json 不在は compact-prep 判定だけを
#   落とし、タスク判定は続ける(lib 破損でタスク側の安全網まで消さない)。
#   停止を不当に妨げない(exit 2 は一切使わない)。
set -euo pipefail

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
(. "$LIB") >/dev/null 2>&1 || exit 0
# shellcheck source=/dev/null
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0

# 1停止チェーン1回: 既にこの停止連鎖で block 済みなら停止を許可する(無限ループ・強制停止回避)。
# jq の `// empty` は false も空に落とすため、literal "true" のときだけ素通しになる。
[[ "$(hook_field '.stop_hook_active')" == "true" ]] && exit 0

# --- 未完タスク(ファントムツール呼び出しからの復帰)---
task_reason=""
sid="$(hook_field '.session_id')"
# session_id は信頼できない外部入力。tasks dir 名は UUID 形式なのでホワイトリスト検証し、
# 想定外文字(/ や .. によるパストラバーサル、改行等)はすべて素通り(fail-open)。
if [[ -n "$sid" && "$sid" =~ ^[A-Za-z0-9_-]+$ && -d "$HOME/.claude/tasks/$sid" ]]; then
  shopt -s nullglob
  # ファイル単位で評価し、破損 json はその1件だけスキップする
  # (jq -s 一括だと1件破損で検出ごと無効化されるため)。
  for task_file in "$HOME/.claude/tasks/$sid"/*.json; do
    status="$(jq -r '.status // empty' "$task_file" 2>/dev/null)" || continue
    if [[ "$status" == "pending" || "$status" == "in_progress" ]]; then
      # 中立文: 「続けろ」と書かない。ファントムなら呼び直し、人間待ち・完了ならそのまま停止を
      # Claude 自身に選ばせる。人間の確認待ちでは継続しないことを明示してエスカレーションを守る。
      task_reason="停止が検出されたが、未完了のタスクが残っている。状況を確認せよ。ツール呼び出しを発行したつもりで実際には発火していない場合(ファントムツール呼び出し)は、その呼び出しを実行して作業を再開せよ。一方、人間の判断・入力・確認を待っている場合、または実際に作業が完了している場合は、継続するな——そのまま停止して人間を待て(何もせず再度停止すればこのナッジは繰り返さない)。"
      break
    fi
  done
  shopt -u nullglob
fi

# --- compact-prep の自動実行 ---
# 更新が要るなら compact_reason へ文面を、打ち止めの書込先を NUDGE_FILE / NUDGE_LINE へ置く。
# 値を stdout でなくグローバルへ返すのは、コマンド置換の subshell だと打ち止めの記録が
# 親へ戻らないため(実際に取りこぼした)。
#
# 打ち止めは 2 段。同一ユーザーターンで 2 回目を出さないのと、state が新鮮に
# ならないまま連続したら黙るのと。後者が無いと、モデルが構造検証を通る state を
# 書けない状況(validator 不在・plan mode の継続)で毎ユーザーターン介入が続く。
NUDGE_LIMIT=3

# 構造検証は compact-prep の validator を借用する(不在なら検査せず通す = 鮮度判定のみへ縮退)。
# precompact-gate と同じ検査を通さないと、両者の言う「新鮮」がずれる。
state_structure_ok() {
  local validator="$HOME/.claude/skills/compact-prep/scripts/validate-state.sh"
  [[ -r "$validator" ]] || return 0
  bash "$validator" "$(ctx_state_file "$1")" >/dev/null 2>&1
}

compact_prep_reason() {
  local ctx usage_file pct updated_at turn nudge_file nudged_turn nudged_count
  local state_path decisions_path

  ctx="$(claude_ctx_key "$(hook_field '.transcript_path')")"
  [[ -n "$ctx" ]] || return 0

  usage_file="$(ctx_usage_file "$ctx")"
  [[ -r "$usage_file" ]] || return 0
  pct="$(jq -r '.pct // empty' "$usage_file" 2>/dev/null || true)"
  updated_at="$(jq -r '.updated_at // empty' "$usage_file" 2>/dev/null || true)"
  pct="${pct%%.*}"
  case "$pct" in "" | *[!0-9]*) return 0 ;; esac
  case "$updated_at" in "" | *[!0-9]*) return 0 ;; esac
  (($(date +%s) - updated_at > $(claude_ctx_usage_stale_secs))) && return 0
  ((10#$pct < $(claude_ctx_auto_refresh_pct))) && return 0

  # 圧縮直後は復帰注入(context-pressure-notify)が先。ここで割り込まない
  [[ -f "$(ctx_compacted_marker "$ctx")" ]] && return 0

  nudge_file="$(ctx_stop_nudged_turn_file "$ctx")"
  # 新鮮になったら連続回数を捨てる(次に古くなった時また 3 回まで出せる)
  if claude_ctx_state_is_fresh "$ctx" && state_structure_ok "$ctx"; then
    rm -f "$nudge_file" 2>/dev/null || true
    return 0
  fi

  # turn が読めなければ打ち止めを数えられない。数えられない介入は毎停止に化けるので、
  # ナッジ自体を諦める(marker を書けないときブロックを諦める precompact-gate と同じ)。
  turn="$(cat "$(ctx_turn_file "$ctx")" 2>/dev/null || true)"
  case "$turn" in "" | *[!0-9]*) return 0 ;; esac

  nudged_turn="$(awk 'NR == 1 { print $1; exit }' "$nudge_file" 2>/dev/null || true)"
  nudged_count="$(awk 'NR == 1 { print $2; exit }' "$nudge_file" 2>/dev/null || true)"
  # 破損した記録は「記録なし」へ倒す。片方の列だけ読めた状態で上限だけ成立すると、
  # 回数を減らす経路(新鮮化)に到達しないまま恒久的にナッジが黙る。
  case "$nudged_turn" in "" | *[!0-9]*)
    nudged_turn=""
    nudged_count=0
    ;;
  esac
  case "$nudged_count" in "" | *[!0-9]*) nudged_count=0 ;; esac
  [[ -n "$nudged_turn" && "$turn" == "$nudged_turn" ]] && return 0
  ((nudged_count >= NUDGE_LIMIT)) && return 0

  # 記録は block を出せると分かってから確定する(出力前に確定すると、出力に失敗した
  # ターンで指示が届かないのに回数だけ進む)。可否は一時ファイルで試す — 本体を
  # 空書込で試すと、その後に中断したとき連続回数が 0 に戻り上限が効かなくなる。
  umask 077
  claude_ctx_cache_ensure "$ctx" || return 0
  # 確定先が通常ファイルでなければ mv が失敗して回数が進まない = 打ち止めが効かない
  [[ ! -e "$nudge_file" || (-f "$nudge_file" && ! -L "$nudge_file") ]] || return 0
  NUDGE_TMP="$nudge_file.tmp"
  rm -f "$NUDGE_TMP" 2>/dev/null || true
  (
    set -C
    : >"$NUDGE_TMP"
  ) 2>/dev/null || return 0
  NUDGE_FILE="$nudge_file"
  NUDGE_LINE="$turn $((nudged_count + 1))"

  # Claude はセッション内から自分の transcript_path を知れないため、compact-prep が
  # 使う実パスはここで文面へ埋めて渡す(推測名でファイルを作らせない)。
  state_path="$(ctx_state_file "$ctx")"
  decisions_path="$(ctx_decisions_file "$ctx")"
  compact_reason="コンテキスト使用率が ${pct}% で、state file が現在の作業状態を反映していない。作業の切れ目なので、停止する前に compact-prep skill を実行して state file(${state_path})を更新せよ(決定ログ: ${decisions_path})。この state file の更新に限り人間への確認は不要で、実行してよいか尋ねずに進めてよい(免除はここまで。skill 内で行う他の判断・破壊的操作・外向き操作は従来どおり人間に確認せよ)。plan mode でファイルを書けない場合、および人間の判断・入力・確認を待っている場合は、更新せずそのまま停止してよい(保留中の問いがあれば再掲して停止せよ)。/compact の実行を人間に依頼するのは使用率 50% 以上のときだけでよい。"
}

# lib を取り込めなければこの判定だけを落とす(`|| exit 0` にするとタスク側も消える)。
compact_reason=""
if source_hook_lib context-paths.sh &&
  type claude_ctx_state_is_fresh claude_ctx_usage_stale_secs \
    claude_ctx_auto_refresh_pct ctx_stop_nudged_turn_file >/dev/null 2>&1; then
  compact_prep_reason || compact_reason=""
fi

[[ -n "$task_reason$compact_reason" ]] || exit 0

# 作業復帰(タスク)を先、家事(compact-prep)を後に置く
reason="$task_reason"
[[ -n "$compact_reason" ]] && reason="${reason:+$reason }$compact_reason"

jq -n --arg reason "$reason" '{decision: "block", reason: $reason}' || exit 0

if [[ -n "${NUDGE_FILE:-}" ]]; then
  printf '%s' "$NUDGE_LINE" 2>/dev/null >"$NUDGE_TMP" &&
    mv -f "$NUDGE_TMP" "$NUDGE_FILE" 2>/dev/null ||
    rm -f "$NUDGE_TMP" 2>/dev/null || true
fi
exit 0
