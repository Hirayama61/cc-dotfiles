#!/usr/bin/env bash
# context-paths.sh — コンテキスト逼迫対策(context-pressure)の cache パス単一情報源。
#
# statusline(python)が書く usage.json を hook 群(bash)が読む受け渡しバッファ、
# state.md(圧縮前の判断構造退避)、decisions.jsonl(人間発の決定ログ)、marker 群の
# パスをここへ集約する。flag-paths.sh(state dir)とは寿命が違う: こちらは使い捨ての
# 機械間バッファで、XDG cache 配下に置き vault にも state にも入れない。
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

claude_ctx_cache_dir() {
  printf '%s/%s' "$(claude_ctx_cache_base)" "${1:-}"
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

ctx_usage_file() { printf '%s/usage.json' "$(claude_ctx_cache_dir "${1:-}")"; }
ctx_state_file() { printf '%s/state.md' "$(claude_ctx_cache_dir "${1:-}")"; }
ctx_decisions_file() { printf '%s/decisions.jsonl' "$(claude_ctx_cache_dir "${1:-}")"; }
ctx_turn_file() { printf '%s/turn' "$(claude_ctx_cache_dir "${1:-}")"; }
ctx_notified_pct_file() { printf '%s/notified-pct' "$(claude_ctx_cache_dir "${1:-}")"; }
ctx_grace_turn_file() { printf '%s/grace-turn' "$(claude_ctx_cache_dir "${1:-}")"; }
ctx_compacted_marker() { printf '%s/compacted' "$(claude_ctx_cache_dir "${1:-}")"; }
ctx_precompact_blocked_marker() { printf '%s/precompact-blocked' "$(claude_ctx_cache_dir "${1:-}")"; }
ctx_override_marker() { printf '%s/override' "$(claude_ctx_cache_dir "${1:-}")"; }

# 直接実行(SKILL / python テスト等の非 source 文脈)用ディスパッチャ。
#   context-paths.sh key <transcript_path>
#   context-paths.sh dir|ensure|usage|state|decisions|turn <ctx>
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  set -euo pipefail
  case "${1:-}" in
  key) claude_ctx_key "${2:-}" ;;
  dir) claude_ctx_cache_dir "${2:-}" ;;
  ensure) claude_ctx_cache_ensure "${2:-}" || exit 1; exit 0 ;;
  usage) ctx_usage_file "${2:-}" ;;
  state) ctx_state_file "${2:-}" ;;
  decisions) ctx_decisions_file "${2:-}" ;;
  turn) ctx_turn_file "${2:-}" ;;
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
USAGE
    exit 1
    ;;
  esac
  printf '\n'
fi
