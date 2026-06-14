#!/usr/bin/env bash
# hook-input.sh — PreToolUse/PostToolUse 等 hook の stdin JSON 取り込みと
# フィールド抽出の共通ヘルパ(参謀ゲート群の冒頭定型を集約)。
#
# 各 hook 冒頭の「command -v jq || exit 0 / input=$(cat) / echo|jq -r ... // empty」の
# 重複(jq ガード持ち多数)を1箇所へ寄せる。挙動は従来と等価(fail-open を保つ)。
#
# 使い方(各 hook 冒頭の定型):
#   set -euo pipefail
#   LIB="$HOME/.claude/hooks/lib/hook-input.sh"
#   [[ -r "$LIB" ]] || exit 0
#   # shellcheck source=/dev/null
#   . "$LIB" 2>/dev/null || exit 0
#   hook_init || exit 0                 # jq 不在なら exit 0(fail-open)。stdin を HOOK_INPUT へ
#   cmd="$(hook_command)"; [[ -z "$cmd" ]] && exit 0
#
# bash 3.2 互換(連想配列・${var,,}・grep -P を使わない)。source 時に呼び出し元の
# set 状態を汚さない。fail-open(jq 不在・空入力・破損 JSON でエラーにしない)は
# resolve-repo-key.sh / resolve-git-target.sh と同作法。strict 化は直接実行ガード内のみ。
#
# 注意: この lib 自身の source の fail-open は lib 化できない(鶏卵)。各 hook 冒頭の
# `[[ -r "$LIB" ]] || exit 0` と `. "$LIB" 2>/dev/null || exit 0` がそれを担う。

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
hook_field() {
  printf '%s' "${HOOK_INPUT:-}" | jq -r "${1} // empty" 2>/dev/null || true
}

# hook_field_raw <jq-path>: `// empty` を掛けない変種(false/0/空文字を潰さない判定向け)。
hook_field_raw() {
  printf '%s' "${HOOK_INPUT:-}" | jq -r "${1}" 2>/dev/null || true
}

# よく使うフィールドのショートカット(各 hook の重複を減らす)。
hook_tool_name() { hook_field '.tool_name'; }
hook_command() { hook_field '.tool_input.command'; }
hook_file_path() { hook_field '.tool_input.file_path'; }
hook_cwd() { hook_field '.cwd'; }
hook_session_id() { hook_field '.session_id'; }

# source_hook_lib <basename>: $HOME/.claude/hooks/lib/<basename> をガード付きで source。
# [[ -r ]] 確認 → subshell 試験 source(構文破損なら本 source を回避)→ 本 source。
# いずれか失敗で return 1(呼び出し側で || exit 0 = fail-open)。bare source が破損 lib で
# exit 2 に化ける事故(A-1)を塞ぐための正規経路。
source_hook_lib() {
  local lib="$HOME/.claude/hooks/lib/${1}"
  [[ -r "$lib" ]] || return 1
  # shellcheck source=/dev/null
  (. "$lib") >/dev/null 2>&1 || return 1
  # shellcheck source=/dev/null
  . "$lib" 2>/dev/null || return 1
  return 0
}
