#!/usr/bin/env bash
# hook-input.sh — PreToolUse/PostToolUse 等 hook の stdin JSON 取り込みと
# フィールド抽出の共通ヘルパ(参謀ゲート群の冒頭定型を集約)。
#
# 各 hook 冒頭の「command -v jq || exit 0 / input=$(cat) / echo|jq -r ... // empty」の
# 重複(jq ガード持ち多数)を1箇所へ寄せる。挙動は従来と等価(fail-open を保つ)。
#
# 使い方(各 hook 冒頭の定型)。hook-input.sh 自身が構文破損しても fail-open する必要が
# あるが、lib 自身の取り込みは lib 化できない(鶏卵)。そこで block-test-deletion が
# PATTERN_LIB に対して行うのと同じ「subshell 試験 source → 本 source」を各 hook 冒頭で
# 手書きする(`. "$LIB" 2>/dev/null || exit 0` 単独だと、構文破損 lib は bash の parse
# エラーで status 2 を返し `|| exit 0` に到達せず PreToolUse hook が exit 2=ブロックに
# 化けるため。実機確認済み):
#   set -euo pipefail
#   LIB="$HOME/.claude/hooks/lib/hook-input.sh"
#   [[ -r "$LIB" ]] || exit 0
#   # shellcheck source=/dev/null
#   ( . "$LIB" ) >/dev/null 2>&1 || exit 0    # 構文破損を subshell で検出(本 source 前)
#   # shellcheck source=/dev/null
#   . "$LIB" 2>/dev/null || exit 0
#   hook_init || exit 0                       # jq 不在なら exit 0(fail-open)。stdin を HOOK_INPUT へ
#   cmd="$(hook_command)"; [[ -z "$cmd" ]] && exit 0
#
# bash 3.2 互換(連想配列・${var,,}・grep -P を使わない)。source 時に呼び出し元の
# set 状態を汚さない。fail-open(jq 不在・空入力・破損 JSON でエラーにしない)は
# resolve-repo-key.sh / resolve-git-target.sh と同作法。strict 化は直接実行ガード内のみ。

# jq 不在なら return 1(呼び出し側は hook_init || exit 0 で素通し)。
# stdin 全体を HOOK_INPUT へ読み込む(空入力でもエラーにしない)。
hook_init() {
  command -v jq >/dev/null 2>&1 || return 1
  HOOK_INPUT="$(cat || true)"
  return 0
}

# hook_field <jq-path>: HOOK_INPUT から jq -r で抽出。`// empty` で null/不在を空文字に。
# echo の差異(末尾改行・バックスラッシュ解釈)を避けるため printf '%s' で渡す。
# jq 失敗(破損 JSON 等)は空文字で握る(fail-open)。
# 不変条件: 引数 <jq-path> は呼び出し側コード内のリテラルに限定する(外部入力=stdin の
# JSON 値をフィルタ式へ渡すと任意 jq 式評価=jq インジェクションになる。値は HOOK_INPUT
# 側にのみ入れ、フィルタはリテラルに保つ)。
hook_field() {
  printf '%s' "${HOOK_INPUT:-}" | jq -r "${1} // empty" 2>/dev/null || true
}

# よく使うフィールドのショートカット(各 hook の重複を減らす)。
hook_tool_name() { hook_field '.tool_name'; }
hook_command() { hook_field '.tool_input.command'; }
hook_file_path() { hook_field '.tool_input.file_path'; }
hook_cwd() { hook_field '.cwd'; }
hook_session_id() { hook_field '.session_id'; }

# source_hook_lib <basename>: $HOME/.claude/hooks/lib/<basename> をガード付きで source。
# [[ -r ]] 確認 → subshell 試験 source(構文破損なら本 source を回避)→ 本 source。
# いずれか失敗で return 1(呼び出し側で `|| exit 0` = fail-open、または `if source_hook_lib`
# で lib 無し時の素判定継続)。bare source が破損 lib で exit 2 に化ける事故(A-1)を塞ぐ
# 正規経路で、git ゲート群の resolve-git-target / resolve-base-ref / flag-paths 取り込みは
# この1関数へ統一済み。
# 引数 <basename> は呼び出し側リテラル限定(外部入力を渡すと $HOME 外 source の恐れ)。
source_hook_lib() {
  # 引数は basename リテラル限定(下記 docstring)。万一 path 区切り(空含む)が
  # 混じったら $HOME 外 source を避けるため拒否する(防御的。現状の全呼出はリテラル)。
  case "${1:-}" in */* | "") return 1 ;; esac
  local lib="$HOME/.claude/hooks/lib/${1}"
  [[ -r "$lib" ]] || return 1
  # shellcheck source=/dev/null
  (. "$lib") >/dev/null 2>&1 || return 1
  # shellcheck source=/dev/null
  . "$lib" 2>/dev/null || return 1
  return 0
}
