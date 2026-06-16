#!/usr/bin/env bash
# PreToolUse(Bash): push 済コミットの `git commit --amend` をブロックする。
# push 済 HEAD の amend は force-push を誘発する履歴書換のため Claude には禁止し、人間が
# ! バイパスで判断・実行する。未 push のローカルコミットの amend は許可する(直前の未 push を
# 直す通常作業は残す)。force-push を誘発する「push 済 amend」だけ精密に止める(Decisions/
# cc-dotfiles/2026-06-04-force-pushとpush済amendをhookでブロック)。
#
# 判定対象は hook プロセスの cwd ではなく、コマンドが実際に操作する working dir。
# `cd <wt> && git commit --amend` / `git -C <wt> commit --amend` の実対象を resolve-git-target.sh
# のプリミティブで解決し、その dir の HEAD で push 済判定する(dispatcher 型運用での cross-repo /
# 別 worktree 誤判定対策。Knowledge/pushゲートフックがプライマリrepo結合でcross-repo-push誤判定)。
# 解決は cmd 全体ではなく「amend を含む commit セグメント単位」で行う(F-002): 複数 git commit
# が別 repo/worktree を指す場合に取り違えないため、cd を畳んだ仮想 cwd を per-amend に適用する。
# push 済判定は `git branch -r --contains HEAD` が非空か。
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
# bash 3.2 / BSD grep 互換: \b / \s / grep -P / 連想配列 / ${var,,} を使わない(--amend 検出は
# lib の segment_has_option に委譲。トークン分割 + クォート1段除去で語境界ハックを廃した)。
# 安全側設計: jq 無し / 空コマンド / lib 不在 / git 外 / HEAD 不明なら exit 0(通す)。
set -euo pipefail

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$LIB" ) >/dev/null 2>&1 || exit 0
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0
cmd="$(hook_command)"; [[ -z "$cmd" ]] && exit 0
cwd="$(hook_cwd)"; [[ -z "$cwd" ]] && cwd="$PWD"

source_hook_lib resolve-git-target.sh || exit 0

# 当該セグメントの HEAD が push 済(remote 到達)なら 0 を返す(= block すべき)。
# git 外 / unborn HEAD / 解決不能は非 0(= このセグメントは skip)。
amend_segment_is_pushed() {
  local dir="${1:-}"
  [[ -z "$dir" ]] && return 1
  git -C "$dir" rev-parse --is-inside-work-tree &>/dev/null || return 1
  # unborn HEAD(コミット皆無)では branch -r --contains がエラーになるので先にガード。
  git -C "$dir" rev-parse --verify -q HEAD >/dev/null 2>&1 || return 1
  local remote_branches
  remote_branches="$(git -C "$dir" branch -r --contains HEAD 2>/dev/null || echo "")"
  [[ -n "$remote_branches" ]]
}

# amend dir は cmd 全体ではなく「amend を含む commit セグメント単位」で解決する(F-002)。
# 複数 git commit(別 repo/worktree)の取り違えを防ぐため、resolve_git_target_dir の
# cd 畳み込み(rule 2)を per-amend に展開: セグメントを順に走査し cd で仮想 cwd を更新、
# amend を含む commit セグメントは「segment 内 git -C があればそれ、無ければ畳んだ cwd」で
# 判定する。いずれかの amend セグメントが push 済なら block。
current="$cwd"
while IFS= read -r seg; do
  [[ -z "$seg" ]] && continue

  cdir="$(_leading_cd_dir_of_segment "$seg")"
  if [[ -n "$cdir" ]]; then
    abs="$(_abs_dir "$cdir" "$current")"
    [[ -n "$abs" ]] && current="$abs"
    continue
  fi

  [[ "$(git_subcommand_of_segment "$seg")" == "commit" ]] || continue
  # --amend 検出は lib の quote-aware ヘルパに委譲(`git commit "--amend"` の素通りも塞ぐ)。
  segment_has_option "$seg" --amend || continue

  seg_cdir="$(_git_c_dir_of_segment "$seg")"
  if [[ -n "$seg_cdir" ]]; then
    amend_dir="$(_abs_dir "$seg_cdir" "$current")"
    [[ -z "$amend_dir" ]] && amend_dir="$current"
  else
    amend_dir="$current"
  fi

  if amend_segment_is_pushed "$amend_dir"; then
    echo "ブロック: push 済コミットの amend は force-push を誘発する履歴書換のため禁止。新しい append-commit で修正すること。どうしても必要なら人間が ! プレフィックスで実行すること。" >&2
    exit 2
  fi
done < <(split_git_segments "$cmd")

exit 0
