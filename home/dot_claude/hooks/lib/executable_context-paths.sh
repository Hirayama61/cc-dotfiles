#!/usr/bin/env bash
# context-paths.sh — コンテキスト逼迫対策(context-pressure)の cache パス単一情報源。
#
# statusline(python)が書く usage.json を hook 群(bash)が読む受け渡しバッファ、
# state.md(圧縮前の判断構造退避)、decisions.jsonl(人間発の決定ログ)、marker 群の
# パスをここへ集約する。flag-paths.sh(state dir)とは寿命が違う: こちらは使い捨ての
# 機械間バッファで、XDG cache 配下に置き vault にも state にも入れない。
#
# あわせて state-stamp の行書式(生成・解釈)と state file の鮮度判定を持つ。
# 鮮度は precompact-gate と stop-nudge の両方が使うため、閾値も判定もここが唯一の
# 定義点になる(片方だけずれると /compact が止まらないか、逆に止まり続ける)。
#
# ctx キーは flag_ctx_key(transcript_path 基準)と同じ導出だが、ここでは
# ディレクトリ segment に使うため sanitize を強化する(空 / . / .. / スラッシュ含みを
# 拒否)。python 側(statusline-command.py)が同じ導出を再実装しており、両者の
# 等価性は tests/lib/context-paths.bats の二言語契約テストで固定する。
#
# bash 3.2 互換・source 時に set 状態を汚さない・fail-open は flag-paths.sh と同作法。

# cache 基底。XDG_CACHE_HOME が絶対パスでなければ $HOME/.cache へ倒す
# (相対パスは呼び出し側 cwd 依存で予測不能になるため)。
claude_ctx_cache_base() {
  local base="${XDG_CACHE_HOME:-}"
  case "$base" in
  /*) ;;
  *) base="$HOME/.cache" ;;
  esac
  printf '%s/claude-context' "$base"
}

# transcript_path / session_id から ctx キーを導出し、dir segment として安全な形に
# 検証する。不正(空 / . / .. / スラッシュ残存)は空を返す(呼び出し側は空で素通し)。
claude_ctx_key() {
  local raw="${1:-}"
  [[ -z "$raw" ]] && return 0
  local key
  key="$(basename -- "${raw%.jsonl}" 2>/dev/null || true)"
  case "$key" in
  "" | . | .. | */*) return 0 ;;
  esac
  printf '%s' "$key"
}

# accessor は SKILL からの直接実行(dispatcher)にも公開されるため、caller の
# claude_ctx_key 検証に依存せずここでも segment を再検証する
# (不正は空 stdout + 非ゼロ終了。dispatcher 経由では set -e により無出力で終了する)。
claude_ctx_cache_dir() {
  case "${1:-}" in
  "" | . | .. | */*) return 1 ;;
  esac
  printf '%s/%s' "$(claude_ctx_cache_base)" "$1"
}

# ctx dir を 0700 で用意・検証する。python 側(statusline)の mkdir も 0700 で揃える。
# 検証は flag-paths.sh の claude_flag_dir_ensure と同じ範囲(実 dir・非 symlink・
# 自ユーザ所有・mode 0700)。失敗は非ゼロ return(書込側は中止、読取側は fail-open)。
claude_ctx_cache_ensure() {
  local ctx="${1:-}"
  [[ -z "$ctx" ]] && return 1
  local dir
  dir="$(claude_ctx_cache_dir "$ctx")"
  (umask 077 && mkdir -p "$dir") 2>/dev/null || return 1
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  local owner
  owner="$(stat -f '%u' "$dir" 2>/dev/null || printf '%s' -1)"
  [[ "$owner" == "$(id -u)" ]] || return 1
  chmod 700 "$dir" 2>/dev/null || return 1
  return 0
}

# dir が不正(空)なら "/<name>" を返さず空のまま失敗する(caller は空/存在チェックで素通る)。
_ctx_file() {
  local d
  d="$(claude_ctx_cache_dir "${1:-}")" || return 1
  printf '%s/%s' "$d" "$2"
}
ctx_usage_file() { _ctx_file "${1:-}" usage.json; }
ctx_state_file() { _ctx_file "${1:-}" state.md; }
ctx_decisions_file() { _ctx_file "${1:-}" decisions.jsonl; }
ctx_turn_file() { _ctx_file "${1:-}" turn; }
ctx_notified_pct_file() { _ctx_file "${1:-}" notified-pct; }
ctx_grace_turn_file() { _ctx_file "${1:-}" grace-turn; }
ctx_state_stamp_file() { _ctx_file "${1:-}" state-stamp; }
ctx_stop_nudged_turn_file() { _ctx_file "${1:-}" stop-nudged-turn; }
ctx_compacted_marker() { _ctx_file "${1:-}" compacted; }
ctx_precompact_blocked_marker() { _ctx_file "${1:-}" precompact-blocked; }
ctx_override_marker() { _ctx_file "${1:-}" override; }

# state-stamp の 1 行を組み立てる。pct が数値でなければ "-"(不明)を置く。
# 圧縮直後は postcompact-marker が usage.json を消すため、pct 不明のまま
# state を確定する経路が実際に通る。
claude_ctx_state_stamp_line() {
  local turn="${1:-}" pct="${2:-}"
  case "$pct" in "" | *[!0-9]*) pct="-" ;; esac
  printf '%s %s' "$turn" "$pct"
}

# state-stamp の 1 列目(turn)または 2 列目(pct)を取り出す。
# 数値でなければ空を返す("-" の pct はここで空になる)。
claude_ctx_state_stamp_field() {
  local ctx="${1:-}" column="${2:-}" stamp_file value
  stamp_file="$(ctx_state_stamp_file "$ctx")" || return 0
  [[ -r "$stamp_file" ]] || return 0
  value="$(awk -v c="$column" 'NR == 1 { print $c; exit }' "$stamp_file" 2>/dev/null || true)"
  case "$value" in "" | *[!0-9]*) return 0 ;; esac
  printf '%s' "$value"
}

# 鮮度の許容差。turn は会話が進んだ量、pct は 1 ターン内で大量にツールを回した量を測る。
# 2 次元あるのは、turn 差だけでは「1 ターンで 30% から 50% まで消費する」形を検知できないため。
claude_ctx_state_fresh_turns() { printf '%s' 3; }
claude_ctx_state_fresh_pct() { printf '%s' 10; }

# usage.json をこの秒数より古ければ現在の使用率を表さないとみなす。
# 自動更新ライン。ここから先は compact-prep を人間の承認なしで走らせる。
# どちらも通知・ゲート・停止時ナッジが同じ値を見る必要がある(片方だけ動かすと
# 「通知は出るがナッジは出ない」に静かに割れる)。
claude_ctx_usage_stale_secs() { printf '%s' 1800; }
claude_ctx_auto_refresh_pct() { printf '%s' 30; }

# state file が現在の作業状態を表しているか。0 = 新鮮 / 1 = 古い or 不明。
# 不明を「古い」へ倒せるのは、呼び出し側のブロックがいずれも有界だから
# (precompact-gate は 1 ctx 1 回、stop-nudge は 1 ユーザーターン 1 回)。
claude_ctx_state_is_fresh() {
  local ctx="${1:-}"
  local state_file stamped_turn turn stamped_pct pct usage_file updated_at

  state_file="$(ctx_state_file "$ctx")" || return 1
  [[ -f "$state_file" ]] || return 1

  stamped_turn="$(claude_ctx_state_stamp_field "$ctx" 1)"
  [[ -n "$stamped_turn" ]] || return 1
  turn="$(cat "$(ctx_turn_file "$ctx")" 2>/dev/null || true)"
  case "$turn" in "" | *[!0-9]*) return 1 ;; esac

  # 10# を付けるのは先頭ゼロの 8 進解釈を避けるため。算術エラーは非ゼロ終了になり、
  # || で「新鮮」側へ倒れる位置があるので黙って素通しになる
  ((10#$turn >= 10#$stamped_turn)) || return 1
  ((10#$turn - 10#$stamped_turn < $(claude_ctx_state_fresh_turns))) || return 1

  # pct は副条件。片方でも読めなければ turn 差だけで判定する(素通し側)。
  # 古い usage.json は現在の使用率を表さないので、同じく pct 次元を課さない
  # (呼び出し側で鮮度を見ない経路があるため、判定はここに置く)。
  stamped_pct="$(claude_ctx_state_stamp_field "$ctx" 2)"
  [[ -n "$stamped_pct" ]] || return 0
  usage_file="$(ctx_usage_file "$ctx")" || return 0
  updated_at="$(jq -r '.updated_at // empty' "$usage_file" 2>/dev/null || true)"
  case "$updated_at" in "" | *[!0-9]*) return 0 ;; esac
  (($(date +%s) - updated_at > $(claude_ctx_usage_stale_secs))) && return 0
  pct="$(jq -r '.pct // empty' "$usage_file" 2>/dev/null || true)"
  pct="${pct%%.*}"
  case "$pct" in "" | *[!0-9]*) return 0 ;; esac

  # 圧縮で使用率は下がる。減少は古さの証拠にならない
  ((10#$pct >= 10#$stamped_pct)) || return 0
  ((10#$pct - 10#$stamped_pct < $(claude_ctx_state_fresh_pct))) || return 1
  return 0
}

# 直接実行(SKILL / python テスト等の非 source 文脈)用ディスパッチャ。
#   context-paths.sh key <transcript_path>
#   context-paths.sh dir|ensure|usage|state|decisions|turn|stamp <ctx>
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  set -euo pipefail
  case "${1:-}" in
  key) claude_ctx_key "${2:-}" ;;
  dir) claude_ctx_cache_dir "${2:-}" ;;
  ensure)
    claude_ctx_cache_ensure "${2:-}" || exit 1
    exit 0
    ;;
  usage) ctx_usage_file "${2:-}" ;;
  state) ctx_state_file "${2:-}" ;;
  decisions) ctx_decisions_file "${2:-}" ;;
  turn) ctx_turn_file "${2:-}" ;;
  stamp) ctx_state_stamp_file "${2:-}" ;;
  *)
    cat >&2 <<'USAGE'
Usage: context-paths.sh <subcommand> <args>
  key      <transcript_path>
  dir      <ctx>
  ensure   <ctx>
  usage    <ctx>
  state    <ctx>
  decisions <ctx>
  turn     <ctx>
  stamp    <ctx>
USAGE
    exit 1
    ;;
  esac
  printf '\n'
fi
