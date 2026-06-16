#!/usr/bin/env bash
# PreToolUse(Bash): git push の force 系オプションをブロックする。
# force-push は remote 履歴を書き換える不可逆操作で、push 済コミットを破壊しうるため
# Claude には禁止し、人間が ! バイパスで判断・実行する(Decisions/cc-dotfiles/
# 2026-06-04-force-pushとpush済amendをhookでブロック)。
#
# 判定は `git push` を含むセグメントに限定する。コマンドをセグメント分割し、サブコマンドが
# push のセグメント内だけで force フラグを探す。`echo "git push -f"` 等の文字列リテラルや
# `git log | grep push` の誤爆を防ぐ(git_subcommand_of_segment による厳密一致)。force 判定は
# ブランチ非依存(= force フラグの有無のみ)なので target dir 解決は不要。lib は
# セグメント分割 / サブコマンド判定のためだけに source する。
#
# 検出語彙: --force / --force-with-lease[=<refspec>] / --force-if-includes / 短縮 -f
# (-uf / -fu 等の連結束に f を含むもの)。検出は lib の segment_has_option(quote-aware)に
# 委譲し、クォート付きフラグの素通りを構造的に塞ぐ(Knowledge/字句grep型hookはクォート付き
# フラグを取りこぼす)。複数 long は完全一致なので --force が --force-with-lease を巻き込まない。
#
# 既知の限界(意図的に受容・best-effort で敵対防御ではない):
# - refspec の `+` 短縮 force(`git push origin +br` / `+refs/heads/x`)は検知しない。
#   `+` は正規 push にも現れ字句検査での切り分けがリスク高(既存 block-protected-branch-push が
#   refspec 解析を意図的に非対象とするのと同方針)。
# - rebase / cherry-pick は対象外。push 済ブランチの履歴書換はそれら経由でも起きうるが、
#   結果として走る force-push を本 hook が backstop として止めるため十分とする(スコープ確定)。
# - push セグメント内のメッセージ等に force 様トークンがある稀ケースは誤ブロックしうる
#   (push に -m は無いので実質起きにくい)。
#
# bash 3.2 / BSD grep 互換: \b / \s / grep -P / 連想配列 / ${var,,} を使わない(検出は
# lib ヘルパに委譲。トークン分割 + クォート1段除去で語境界ハックを廃した)。
# 安全側設計: jq 無し / 空コマンド / lib 不在なら exit 0(通す)。
set -euo pipefail

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$LIB" ) >/dev/null 2>&1 || exit 0
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0
cmd="$(hook_command)"; [[ -z "$cmd" ]] && exit 0

source_hook_lib resolve-git-target.sh || exit 0

while IFS= read -r seg; do
  [[ -z "$seg" ]] && continue
  [[ "$(git_subcommand_of_segment "$seg")" == "push" ]] || continue
  # push セグメント内の force 系。3 ロング + 短縮 -f(-uf / -fu 等の連結束)を lib の
  # quote-aware ヘルパで判定し、`git push "--force"` / `--force=値` の素通りも塞ぐ。
  # 複数 long は OR 反復呼出(ヘルパ API を単純に保つ)。
  if segment_has_option "$seg" --force ||
    segment_has_option "$seg" --force-with-lease ||
    segment_has_option "$seg" --force-if-includes ||
    segment_has_option "$seg" "" f; then
    echo "ブロック: force-push は remote 履歴を書き換える不可逆操作のため禁止。Claude は append / 通常 push のみ。どうしても必要なら人間が ! プレフィックスで実行すること。" >&2
    exit 2
  fi
done < <(split_git_segments "$cmd")

exit 0
