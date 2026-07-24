#!/usr/bin/env bash
# validate-state.sh — state file の構造検証(compact-prep 手順 4 / precompact-gate が使用)
#
# 5 見出しが定義順にすべて存在し、各節に空白以外の行があることを検査する。
# 出力: PASS / FAIL(理由付き)。exit 0 = PASS、exit 1 = FAIL、exit 2 は使わない
# (PreToolUse のブロックと紛れさせない)。引数不正・ファイル不在も FAIL(exit 1)。
set -euo pipefail

state="${1:-}"
fail() {
  echo "FAIL: $1"
  exit 1
}

[[ -n "$state" ]] || fail "state file のパスが指定されていない"
[[ -r "$state" ]] || fail "state file が読めない: $state"

HEADINGS=(
  "## Active Plan"
  "## Session Decisions"
  "## Constraints and Blockers"
  "## Worker Topology"
  "## Editing Files"
)

prev_line=0
for h in "${HEADINGS[@]}"; do
  line="$(grep -nF -m1 -x "$h" "$state" | cut -d: -f1 || true)"
  [[ -n "$line" ]] || fail "見出しが無い: $h"
  (( line > prev_line )) || fail "見出しの順序が不正: $h"
  prev_line="$line"
done

# 各節の本文が非空か(次の見出しまでに空白以外の行があるか)
total_lines="$(wc -l < "$state" | tr -d ' ')"
i=0
count=${#HEADINGS[@]}
while (( i < count )); do
  h="${HEADINGS[$i]}"
  start="$(grep -nF -m1 -x "$h" "$state" | cut -d: -f1)"
  if (( i + 1 < count )); then
    next="${HEADINGS[$((i + 1))]}"
    end="$(grep -nF -m1 -x "$next" "$state" | cut -d: -f1)"
  else
    end=$((total_lines + 1))
  fi
  body="$(sed -n "$((start + 1)),$((end - 1))p" "$state" | grep -cv '^[[:space:]]*$' || true)"
  (( body > 0 )) || fail "節が空: $h(該当なしでも「なし」と書く)"
  i=$((i + 1))
done

echo "PASS"
exit 0
