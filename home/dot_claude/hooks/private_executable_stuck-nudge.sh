#!/usr/bin/env bash
# stuck-nudge.sh — PostToolUseFailure(Bash) / PostToolUse(Bash) の2イベントに登録。
#
# 同種の Bash コマンドが連続して失敗している(= 同じ問題で試行を重ねて詰まっている)状況を
# 検知し、別アプローチ / codex-consult(別モデルのセカンドオピニオン)を additionalContext で
# 促す。codex-consult「同一問題で3回」の近似。
#
# 失敗の載り方(spike 2026-07-03 確定):
#   失敗 Bash は PostToolUse に来ず、専用イベント PostToolUseFailure に飛ぶ。tool_response の
#   代わりに文字列 error(例 "Exit code 1")と is_interrupt(bool)を持つ。数値 exit code は無い。
#   よって PostToolUseFailure を張り、error が "Exit code <n>" 形式のときだけ失敗として数える
#   (is_interrupt=true や permission 拒否などは数えない)。成功のリセットは PostToolUse で受ける。
#
# 状態機械:
#   - 種別: コマンド先頭の環境変数代入(VAR=val)と "cd x &&" 前置を除いた最初の実行語。
#     種別文字列はファイル名へ直接使わず flag_hash16 でハッシュ化してカウンタキーにする。
#   - 除外リスト: grep rg test [ [[ diff cmp は非 0 が正常挙動の語なので詰まりに数えない。
#   - カウンタは種別ごと独立(別種の失敗は連続性を切らない)。同種の成功でその種別をリセット。
#   - 閾値: 同種 3 回連続失敗でナッジ。
#   - 限界: 種別一致 ≠ 同一問題(git status→git push は同種扱い)。精密化しないことを受容する。
#
# 並行安全 / 1 ctx 1 回: カウンタ加算は数値 RMW(並列でロストしうるが害は timing のみ)。
#   ナッジ発火は stuck_nudged_flag を mkdir で atomic に claim した最初の1回だけ(並列失敗でも
#   高々1回)。claim ディレクトリの存在 = このセッションで発火済み。
# subagent 抑制: 入力に agent_id があれば(subagent 発。spike S-2)即 exit 0。
# rearm: clear|compact で rearm-coding-standards.sh がカウンタ・claim を破棄して再武装する。
#
# 破棄容易性: settings.json.tmpl の PostToolUseFailure(Bash)行 + PostToolUse(Bash)の当該行を
# 外せば無効化できる。試行 2 週間でナッジが体感で邪魔 or 効果ゼロなら破棄 or 閾値引き上げ。
#
# 安全側設計(fail-open): jq 不在 / lib 不達・破損 / ctx 不明 / state 書込不能 / 想定外は
# すべて exit 0 で無音素通り(ナッジは best-effort。ブロックは一切しない)。
set -euo pipefail

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$LIB" ) >/dev/null 2>&1 || exit 0
# shellcheck source=/dev/null
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0

# subagent 内の失敗は数えない(agent_id はメイン発の入力に無い。spike S-2)。
[[ -n "$(hook_field '.agent_id')" ]] && exit 0

source_hook_lib flag-paths.sh || exit 0
# apply 前後の版ずれ(古い flag-paths.sh に新関数が無い)は fail-open。
type stuck_count_flag >/dev/null 2>&1 || exit 0

ctx="$(hook_field '.transcript_path // .session_id')"
ctx="$(flag_ctx_key "$ctx" 2>/dev/null || true)"
[[ -n "$ctx" ]] || exit 0
# ctx は外部入力由来。glob / path に使うためメタ文字を含む値は素通り(正規の basename は通る)。
[[ "$ctx" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0

# 種別(kind): 環境変数代入と "cd x &&" 前置を剥がした最初の実行語。
stuck_command_kind() {
  local c="${1:-}" head
  while :; do
    # 先頭空白を除去
    c="${c#"${c%%[![:space:]]*}"}"
    head="${c%%[[:space:]]*}"
    # 先頭が環境変数代入(VAR=... で = が最初の空白より前)なら剥がす
    case "$head" in
    [A-Za-z_]*=*)
      c="${c#"$head"}"
      continue
      ;;
    esac
    # 先頭が "cd ... &&" なら最初の && まで剥がす
    case "$c" in
    cd\ *"&&"*)
      c="${c#*&&}"
      continue
      ;;
    esac
    break
  done
  c="${c#"${c%%[![:space:]]*}"}"
  printf '%s' "${c%%[[:space:]]*}"
}

cmd="$(hook_command)"
[[ -n "$cmd" ]] || exit 0
kind="$(stuck_command_kind "$cmd")"
[[ -n "$kind" ]] || exit 0

# 非 0 が正常挙動の語は詰まりに数えない(前後空白で単語境界を作る)。
STUCK_EXCLUDE=" grep rg test [ [[ diff cmp "
case "$STUCK_EXCLUDE" in
*" $kind "*) exit 0 ;;
esac

khash="$(flag_hash16 "$kind")"
[[ -n "$khash" ]] || exit 0
count_file="$(stuck_count_flag "$ctx" "$khash")"

event="$(hook_field '.hook_event_name')"

# 成功(PostToolUse): 同種カウンタのみリセット(別種は独立なので触れない)。
if [[ "$event" == "PostToolUse" ]]; then
  rm -f "$count_file" 2>/dev/null || true
  exit 0
fi

# 以降は失敗イベントのみ(matcher で絞るが二重確認)。
[[ "$event" == "PostToolUseFailure" ]] || exit 0

# 実 exit code 失敗のみ数える(割り込み / permission 拒否 / 非 "Exit code" エラーは除外)。
[[ "$(hook_field '.is_interrupt')" == "true" ]] && exit 0
err="$(hook_field '.error')"
exit_re='^Exit code [0-9]+'
[[ "$err" =~ $exit_re ]] || exit 0

# state dir を用意してからカウント(書込不能なら fail-open)。
claude_flag_dir_ensure 2>/dev/null || exit 0
n="$(flag_counter_bump "$count_file")"

THRESHOLD=3
[[ "$n" -ge "$THRESHOLD" ]] || exit 0

# 1 ctx 1 回: mkdir claim を atomic に取れた最初の1回だけナッジ(並列失敗でも高々1回)。
claim="$(stuck_nudged_flag "$ctx")"
mkdir "$claim" 2>/dev/null || exit 0

NOTE="同種のコマンド(${kind})が連続して失敗している(このセッションで一度きりの通知)。同じ問題で試行を重ねて詰まっている可能性がある。手を動かし続ける前に別アプローチを検討し、行き詰まっているなら codex-consult で別モデルのセカンドオピニオンを取ることを検討せよ。種別一致は同一問題の近似であり、無関係な失敗がたまたま同種で連続しただけなら無視してよい。"

jq -n --arg body "$NOTE" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUseFailure",
    additionalContext: $body
  }
}' || exit 0

exit 0
