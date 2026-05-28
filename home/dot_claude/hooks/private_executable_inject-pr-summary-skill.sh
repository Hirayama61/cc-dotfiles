#!/usr/bin/env bash
# inject-pr-summary-skill.sh — PreToolUse(Bash) hook
#
# `gh pr create` / `gh pr edit --body` 系で PR body を組み立てる瞬間に、pr-summary
# skill の速読化規約を additionalContext として注入するリマインド(最後の砦)。
# 本文の質は skill が担うので判定は粗いヒューリスティックで良い。ブロックはしない
# (deny だと正規の PR 作成を止めて摩擦が大きい。本文は到達時点で生成済みなので
# 「skill の規約で見直せ」と促すリマインドに徹する)。
# 安全側設計: jq 不在 / 非該当コマンドはすべて exit 0 で完全素通し。
set -euo pipefail

command -v jq &>/dev/null || exit 0
input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[[ -z "$cmd" ]] && exit 0

# gh pr create、または gh pr edit に body 系フラグ(--body / -b / --body-file /
# -F / --fill)が絡む時だけ発火。それ以外は素通し。
echo "$cmd" | grep -qE '\bgh\s+pr\s+create\b' && match=1 || match=0
if [[ "$match" -eq 0 ]] && echo "$cmd" | grep -qE '\bgh\s+pr\s+edit\b'; then
  echo "$cmd" | grep -qE '(^|\s)(--body|-b|--body-file|-F|--fill)(\s|=|$)' && match=1
fi
[[ "$match" -eq 0 ]] && exit 0

read -r -d '' reminder <<'EOF' || true
PR body を組み立てています。pr-summary skill の速読化規約で見直してください:

- BLUF(結論先出し)→ なぜ → 主な変更(概念単位 最大7)→ 検証 の順。HOW は diff が
  語るので本文で再記述しない。
- 既定は Compact 倒し(迷ったら短く)。1〜2 概念なら見出しゼロ数行。中〜大規模のみ
  Standard。デフォルト表示は ~600〜800 字 / 見出し最大4。超過は <details> へ。
- 反スロップ: 「堅牢/包括的/大幅に/シームレス/活用する」等の誇張・空疎語、自己言及の
  前置き、自明な「まとめ」の再掲、diff の逐語列挙を削る。
- メタルール「事実か。短いか。diff に無いか。」を全文に問う。
- 既存 .github/PULL_REQUEST_TEMPLATE.md の必須項目と Claude Code 末尾トレーラは保持。

詳細は pr-summary skill 本文を参照。
EOF

jq -n --arg body "$reminder" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: $body
  }
}' || exit 0

exit 0
