#!/usr/bin/env bash
# ciwatch-on-pr-create.sh — PostToolUse(Bash)
#
# `gh pr create` の直後に、作成された PR を ci-watch せよと注入する。中継("CodeRabbit から
# コメントが来たので確認をお願いします" を毎回手で送る)を hook で恒久排除するための自動起動。
# capture-decision.sh と同型(注入だけ・即 exit・本体処理はしない)。
#
# 責務分界(Decisions/2026-06-04-ci-watchをhook自動起動のCodeRabbit評価専用skillに再設計 #2/#3):
#   hook は PR 特定 + 最小指示の注入まで。ポーリングは直接起動しない — hook が裏で生やした
#   detached プロセスは harness 管理外で Claude を起こせず、hook を数分ブロックさせると
#   ツール処理列が凍る。実際の待機は Claude が Bash ツール run_in_background:true で
#   poll-checks.sh を起動して行う(harness の自動再呼び出しは bg Bash 限定という機構特性)。
#
# 安全側設計: PostToolUse は tool 実行後なので exit 2 でブロックしても無意味。注入失敗で
# 止めない(jq 不在 / 非対象 / PR 未解決 はすべて exit 0 で無音素通り)。
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
input="$(cat)"
cmd="$(echo "$input" | jq -r '.tool_input.command // empty')"
[ -z "$cmd" ] && exit 0

LIB="$HOME/.claude/hooks/lib/resolve-git-target.sh"
[ -r "$LIB" ] || exit 0
# shellcheck source=/dev/null
. "$LIB"

# `gh pr create` 検知。block-gh-mutations.sh と同じ border/env/flags ERE を、同じく
# normalized_words_of_segment で正規化(トークン化 → 各 _strip_one_quote → 単一空白で再結合)
# してから適用する。これで `gh pr "create"` / `"gh" pr create` のクォート付き素通り
# (Knowledge/字句grep型hookはクォート付きフラグを取りこぼす の層 (b))を block-gh-mutations と
# 対称に塞ぐ。normalized_words_of_segment の `read -r -a` は先頭行しか読まないため、cmd 全体を
# 渡すと2行目以降の `gh pr create`(複数行コマンド)を取りこぼす(生 grep からの後退・F-004)。
# 行で分割し各行を個別に正規化 → grep し、いずれか一致で検知する。
#
# 既知の限界(block-gh-mutations と同じ best-effort): 文字列リテラルや heredoc 本文中の
# `| gh pr create` は BORDER がコマンド境界と区別できず誤検知しうる(block-gh-mutations.sh も
# 同入力を同様に誤検知する受容済み限界)。pr-create は自動起動だが下流 poll-checks の atomic
# mkdir lock で二重 watch にはならないので実害は低い。
FLAGS='(-{1,2}[A-Za-z][A-Za-z0-9-]*(=\S+)?\s+([^-\s]\S*\s+)?)*'
ENV='([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*'
BORDER='(^|[;&|(])[[:space:]]*'
END='(\s|$|[;&|)])'
matched=0
while IFS= read -r line; do
  normalized="$(normalized_words_of_segment "$line")"
  if echo "$normalized" | grep -qE "${BORDER}${ENV}gh\\s+${FLAGS}pr\\s+create${END}"; then
    matched=1
    break
  fi
done <<EOF
$cmd
EOF
[ "$matched" -eq 1 ] || exit 0

# PR 特定は現ブランチ基準(cwd 結合での cross-repo 誤判定を避ける。
# Knowledge/pushゲートフックがプライマリrepo結合でcross-repo-push誤判定)。
# gh pr create には git -C 文法が無く対象は常に hook の .cwd の repo なので、
# push 系のような git -C 解決はせず .cwd の repo で現ブランチ→PR を引く
# (cd X && gh pr create は稀という割り切り。Tasks/.../plan.md §3-A の確定方針)。
cwd="$(echo "$input" | jq -r '.cwd // empty')"
[ -z "$cwd" ] && cwd="$PWD"
git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
branch="$(git -C "$cwd" branch --show-current 2>/dev/null || echo "")"
[ -z "$branch" ] && exit 0

command -v gh >/dev/null 2>&1 || exit 0
# gh pr list は hook プロセスの cwd ではなく対象 repo($cwd)の文脈で実行する。
# branch 取得(git -C "$cwd")と repo を一致させないと、dispatcher 運用で gh が primary
# repo の文脈で走り、別 repo の同名ブランチの PR 番号を誤って拾いうる(F-002)。
pr="$( (cd "$cwd" && gh pr list --head "$branch" --state open --json number --jq '.[0].number') 2>/dev/null || echo "")"
{ [ -z "$pr" ] || [ "$pr" = "null" ]; } && exit 0

# poll-checks.sh が $PWD に依存せず対象 repo を見られるよう owner/repo を注入文に載せる
# (PR #18 CodeRabbit #1: poll-checks の repo 文脈明示)。
repo_spec="$( (cd "$cwd" && gh repo view --json nameWithOwner --jq '.nameWithOwner') 2>/dev/null || echo "")"
# repo が取れないなら無音 exit。空のまま注入すると poll-checks が $PWD fallback に落ち、
# dispatcher 運用で誤 repo を監視する穴が復活する(PR #18 再レビュー A)。
{ [ -z "$repo_spec" ] || [ "$repo_spec" = "null" ]; } && exit 0

NOTE="PR #${pr} が作成された。ci-watch せよ: Bash ツールを run_in_background:true で呼び \`~/.claude/skills/ci-watch/scripts/poll-checks.sh ${pr} ${repo_spec}\` を起動し、全 check が terminal になって harness が起床したら ci-watch の評価フェーズ(未解決 CodeRabbit thread + 失敗 check ログを delegate がフルコンテキストで一次判断 → 人間へ提示)を実行する。返信も適用もしない(assess-only)。"

jq -n --arg body "$NOTE" '{
  hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: $body }
}' || exit 0

exit 0
