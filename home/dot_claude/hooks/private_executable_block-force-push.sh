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
# (-uf / -fu 等の連結束に f を含むもの)。各ロングオプションは末尾境界を個別に持たせて
# 別の交替枝に分け、--force が --force-with-lease を巻き込まないようにする。
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
# bash 3.2 / BSD grep 互換: \b / \s / grep -P / 連想配列 / ${var,,} を使わない。語境界は
# 行頭行末・空白・クォート文字(" ')・= で表現する(block-no-verify と同作法 + クォート対応)。
# 安全側設計: jq 無し / 空コマンド / lib 不在なら exit 0(通す)。
set -euo pipefail

command -v jq &>/dev/null || exit 0
input="$(cat)"
cmd="$(echo "$input" | jq -r '.tool_input.command // empty')"
[[ -z "$cmd" ]] && exit 0

LIB="$HOME/.claude/hooks/lib/resolve-git-target.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
. "$LIB"

while IFS= read -r seg; do
  [[ -z "$seg" ]] && continue
  [[ "$(git_subcommand_of_segment "$seg")" == "push" ]] || continue
  # push セグメント内の force 系。各ロングオプションは末尾境界を分けて誤マッチを防ぐ。
  # 短縮は -f を含むフラグ束(-uf / -fu 等)を捕捉する(block-no-verify の -n 検出と同型)。
  # 語境界の文字クラスにクォート文字 " ' を含め、`git push "--force"` / '--force' /
  # "-f" のクォート付き素通りを塞ぐ(F-001)。`--force` 後境界に = も許し `--force=値` を
  # 捕捉(F-005)。シェル単引用符内なので ' は '\'' でエスケープして埋める。
  if echo "$seg" | grep -qE '(^|[[:space:]"'\''])--force([[:space:]"'\'']|=|$)|(^|[[:space:]"'\''])--force-with-lease([[:space:]"'\'']|=|$)|(^|[[:space:]"'\''])--force-if-includes([[:space:]"'\'']|$)|(^|[[:space:]"'\''])-[a-eg-zA-Z]*f[a-zA-Z]*([[:space:]"'\'']|$)'; then
    echo "ブロック: force-push は remote 履歴を書き換える不可逆操作のため禁止。Claude は append / 通常 push のみ。どうしても必要なら人間が ! プレフィックスで実行すること。" >&2
    exit 2
  fi
done < <(split_git_segments "$cmd")

exit 0
