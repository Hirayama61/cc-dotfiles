#!/usr/bin/env bash
# create-review-flag.sh — self-review skill 手順 5 の review-passed フラグ作成を移設。
#
# Usage: create-review-flag.sh <tier1_lastline> <tier2_lastline> <reason1> <reason2>
#   stdin: 見送り triage 行(`triage: F-NNN 見送り — 理由` 形式、0 行以上)。
#   レビュー対象 repo 内($PWD = 対象 worktree)で呼ばれる前提。gate / postcommit は
#   フラグキーを push 実対象 dir 起点で引くため、別 cwd で実行するとキー基点がずれて
#   恒久ブロックになりうる。
#
# 界面は固定(Tier 判定を再実行しない)。tierN_lastline は skill 手順 1.5 で捕捉した各 Tier
# 出力の最終行、reasonN は 4b で人間が述べた ack 理由(非該当なら空文字)。
#
# フラグの書き方: 4b で集めた Tier ack 理由 + 見送り処置を内容に記録する(touch ではなく
# 内容書込。gate は `-f` 存在のみを見るため互換。説明責任ある証跡)。該当 Tier の理由が空なら
# フラグを書かず中断する(空理由での素通り防止)。既存フラグは子/別経路の自力作成を疑う異常
# として中断する。noclobber(set -C)下の単一 `>` で作成し、作成失敗時は中途半端なフラグを
# 残さず消してから中断する(残骸での誤解除を防ぐ)。
#
# フラグキーは flag-paths.sh が単一情報源。gate(読取)/ postcommit(削除)も同 lib を使うため
# 必ず lib 経由で得る。repo は resolve-repo-key.sh で導出。
set -uo pipefail

tier1_lastline="${1-}"
tier2_lastline="${2-}"
reason1="${3-}"
reason2="${4-}"

# 見送り triage 行(0 行以上)。stdin は先に読み切る。
triage="$(cat)"

LIB_DIR="$HOME/.claude/hooks/lib"

branch="$(git branch --show-current)"
repo="$("$LIB_DIR/resolve-repo-key.sh" "$PWD" 2>/dev/null || true)"
flag="$("$LIB_DIR/flag-paths.sh" review-passed "$repo" "$branch")"
[ -n "$flag" ] || { echo "flag-paths.sh が引けない。中断" >&2; exit 1; }
"$LIB_DIR/flag-paths.sh" dir-ensure \
  || { echo "flag state dir の検証に失敗。中断" >&2; exit 1; }

# Tier 連結の非空チェックは片方の理由だけで素通りするため、該当 Tier ごとに理由必須を個別検証。
if printf '%s\n' "$tier1_lastline" | grep -q '^TIER1-RESULT: DECREASE' \
  && [ -z "$reason1" ]; then
  echo "Tier 1 DECREASE の ack 理由が空。中断" >&2; exit 1
fi
if printf '%s\n' "$tier2_lastline" | grep -q '^TIER2-RESULT: RESURRECT' \
  && [ -z "$reason2" ]; then
  echo "Tier 2 RESURRECT の ack 理由が空。中断" >&2; exit 1
fi

# 既存は手順 2b(子 reviewer read-only)を破った自力作成を疑う異常として中断。
[ -e "$flag" ] && { echo "想定外: review-passed フラグが既存(子/別経路の自力作成を疑う)。中断" >&2; exit 1; }

# noclobber(set -C)下の単一 `>` で作成。[ -e ] 後の窓で競合作成されても、既存なら `>` が
# 失敗する。ack/見送り理由があれば内容を、無ければ空を書く(gate は `-f` 存在のみ参照)。
( set -C
  {
    if [ -n "$reason1" ]; then printf 'tier1-ack: %s\n' "$reason1"; fi
    if [ -n "$reason2" ]; then printf 'tier2-ack: %s\n' "$reason2"; fi
    if [ -n "$triage" ]; then printf '%s\n' "$triage"; fi
  } > "$flag"
) 2>/dev/null \
  || { rm -f "$flag"; echo "review-passed フラグの作成に失敗(既存/権限/state dir)。中断" >&2; exit 1; }

exit 0
