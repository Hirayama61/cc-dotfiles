#!/usr/bin/env bash
# selfcheck-on-stop.sh — Stop hook
#
# ファントムツール呼び出し(Claude がツールを呼んだつもりで実際には発火せず入力待ちで
# 停止する状態)からの復帰用。未完了タスクが残ったまま停止したときだけ、Claude へ中立な
# 自己チェックを促す。呼び直すか/待つかの判別はフックに持たせず、文脈を持つ Claude に委ねる。
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
#
# 安全側設計(fail-open): jq 不在 / session_id 不明 or 不正形式 / tasks 不在 / 想定外は
#   すべて exit 0 で無音素通り。破損 json はそのファイルだけスキップして残りを評価する。
#   停止を不当に妨げない(exit 2 は一切使わない)。
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
input="$(cat)" || exit 0

# 1停止チェーン1回: 既にこの停止連鎖で block 済みなら停止を許可する(無限ループ・強制停止回避)。
# jq 失敗時は active=true 扱い=素通り(fail-open)。
active="$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo true)"
[[ "$active" != "true" ]] || exit 0

sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || echo "")"
[[ -n "$sid" ]] || exit 0
# session_id は信頼できない外部入力。tasks dir 名は UUID 形式なのでホワイトリスト検証し、
# 想定外文字(/ や .. によるパストラバーサル、改行等)はすべて素通り(fail-open)。
[[ "$sid" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0

tdir="$HOME/.claude/tasks/$sid"
[[ -d "$tdir" ]] || exit 0

shopt -s nullglob
files=("$tdir"/*.json)
[[ ${#files[@]} -gt 0 ]] || exit 0

# 未完(pending/in_progress)タスクの有無を数える。ファイル単位で評価し、破損 json は
# その1件だけスキップする(jq -s 一括だと1件破損で検出ごと無効化されるため)。
incomplete=0
for f in "${files[@]}"; do
  st="$(jq -r '.status // empty' "$f" 2>/dev/null)" || continue
  if [[ "$st" == "pending" || "$st" == "in_progress" ]]; then
    incomplete=$((incomplete + 1))
  fi
done
[[ "$incomplete" -gt 0 ]] || exit 0

# 中立文: 「続けろ」と書かない。ファントムなら呼び直し、人間待ち・完了ならそのまま停止、を
# Claude 自身に選ばせる。人間の確認待ちでは継続しないことを明示してエスカレーションを守る。
reason="停止が検出されたが、未完了のタスクが残っている。状況を確認せよ。ツール呼び出しを発行したつもりで実際には発火していない場合(ファントムツール呼び出し)は、その呼び出しを実行して作業を再開せよ。一方、人間の判断・入力・確認を待っている場合、または実際に作業が完了している場合は、継続するな——そのまま停止して人間を待て(何もせず再度停止すればこのナッジは繰り返さない)。"

jq -n --arg reason "$reason" '{decision: "block", reason: $reason}' || exit 0
exit 0
