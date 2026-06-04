#!/usr/bin/env bash
# PreToolUse(Bash): push 済コミットの `git commit --amend` をブロックする。
# push 済 HEAD の amend は force-push を誘発する履歴書換のため Claude には禁止し、人間が
# ! バイパスで判断・実行する。未 push のローカルコミットの amend は許可する(直前の未 push を
# 直す通常作業は残す)。force-push を誘発する「push 済 amend」だけ精密に止める(Decisions/
# cc-dotfiles/2026-06-04-force-pushとpush済amendをhookでブロック)。
#
# 判定対象は hook プロセスの cwd ではなく、コマンドが実際に操作する working dir。
# `cd <wt> && git commit --amend` / `git -C <wt> commit --amend` の実対象を
# resolve-git-target.sh で解決し、その dir の HEAD で push 済判定する(dispatcher 型運用での
# cross-repo / 別 worktree 誤判定対策。Knowledge/pushゲートフックがプライマリrepo結合で
# cross-repo-push誤判定)。push 済判定は `git branch -r --contains HEAD` が非空か。
#
# 既知の限界(意図的に受容・best-effort で敵対防御ではない):
# - remote 未 fetch だと push 済を取りこぼしうる(安全側 = 不明なら通す。人間が ! で対応可)。
# - rebase / cherry-pick は対象外。push 済ブランチの履歴書換はそれら経由でも起きうるが、
#   結果として走る force-push を block-force-push が backstop として止めるため十分とする。
# - commit セグメント内のメッセージ本文に `--amend` 様トークンがあると誤ブロックしうる
#   (例 `git commit -m 'fix --amend bug'`)。完全な切り分けには引数パースが要りリスクが高い
#   ため block-no-verify と同じ判断で受容する。
# - 変数経由の `git -C "$WT"` は静的パースで解決できず cwd フォールバックする
#   (Knowledge/pushゲートはgit-Cの変数を解決できず別ブランチへフォールバック誤ブロックする)。
#   リテラル絶対パス運用が安全。
#
# bash 3.2 / BSD grep 互換: \b / \s / grep -P / 連想配列 / ${var,,} を使わない。語境界は
# 行頭行末・空白で表現する(block-no-verify と同作法)。
# 安全側設計: jq 無し / 空コマンド / lib 不在 / git 外 / HEAD 不明なら exit 0(通す)。
set -euo pipefail

command -v jq &>/dev/null || exit 0
input="$(cat)"
cmd="$(echo "$input" | jq -r '.tool_input.command // empty')"
[[ -z "$cmd" ]] && exit 0
cwd="$(echo "$input" | jq -r '.cwd // empty')"
[[ -z "$cwd" ]] && cwd="$PWD"

LIB="$HOME/.claude/hooks/lib/resolve-git-target.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
. "$LIB"

has_amend=0
while IFS= read -r seg; do
  [[ -z "$seg" ]] && continue
  [[ "$(git_subcommand_of_segment "$seg")" == "commit" ]] || continue
  if echo "$seg" | grep -qE '(^|[[:space:]])--amend([[:space:]]|$)'; then
    has_amend=1
  fi
done < <(split_git_segments "$cmd")
[[ "$has_amend" -eq 0 ]] && exit 0

target_dir="$(resolve_git_target_dir "$cmd" "$cwd")"
git -C "$target_dir" rev-parse --is-inside-work-tree &>/dev/null || exit 0
# unborn HEAD(コミット皆無)では branch -r --contains がエラーになるので先にガード。
git -C "$target_dir" rev-parse --verify -q HEAD >/dev/null 2>&1 || exit 0

remote_branches="$(git -C "$target_dir" branch -r --contains HEAD 2>/dev/null || echo "")"
if [[ -n "$remote_branches" ]]; then
  echo "ブロック: push 済コミットの amend は force-push を誘発する履歴書換のため禁止。新しい append-commit で修正すること。どうしても必要なら人間が ! プレフィックスで実行すること。" >&2
  exit 2
fi

exit 0
