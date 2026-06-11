#!/usr/bin/env bash
# flag-paths.sh — /tmp/claude-sessions ゲートフラグのキー導出規約の単一情報源
# (参謀ゲート Phase 1)。
#
# 背景: review-passed フラグは gate(読取)/ postcommit(削除)/ self-review SKILL(作成)の
# 3者が同じキー文字列を別々に組み立てており、1者でも崩れると恒久ブロック or ゲート無効化に
# なる(完全一致が生命線)。cs-injected も inject / rearm の2者で同じ依存がある。
# キーの組み立てをここへ集約し、消費者は lib の関数経由でのみパスを得る。
#
# キー規約(既存と完全一致。変える時は全消費者と同時に):
#   review-passed-${repo_key}--${safe_branch}
#   design-reviewed-${repo_key}--${safe_branch}      (設計レビューゲート: branch スコープ)
#   design-reviewed-ctx-${repo_key}--${safe_ctx}     (同: セッションスコープ)
#   design-reviewed-pending-${repo_key}              (同: セッション昇格用中間フラグ)
#   trivial-override-ctx-${repo_key}--${safe_ctx}    (Gate 2 の脱出口。内容 = 理由)
#   trivial-override-pending-${repo_key}             (同: 昇格用中間フラグ)
#   design-scope-${repo_key}--${safe_branch}         (Tier 3: 宣言スコープ。1行1 path/glob)
#   design-scope-pending-${repo_key}                 (同: branch 不在時)
#   cs-injected-${ctx}--${scope}
# safe_branch = branch の '/' を '-' へ置換。
# ctx = transcript_path(無ければ session_id)の basename から末尾 .jsonl を除去。
# repo_key は resolve-repo-key.sh、branch は push/commit 実対象 dir
# (resolve-git-target.sh)起点で得る(導出はここではしない)。
#
# bash 3.2 互換・source 時に set 状態を汚染しない・fail-open(空入力でもエラーに
# しない)は resolve-repo-key.sh と同作法。strict 化は直接実行ガード内でのみ行う。

claude_flag_dir() {
  printf '%s' "/tmp/claude-sessions"
}

flag_safe_branch() {
  printf '%s' "${1:-}" | tr '/' '-'
}

review_passed_flag() {
  printf '%s/review-passed-%s--%s' "$(claude_flag_dir)" "${1:-}" "$(flag_safe_branch "${2:-}")"
}

design_reviewed_flag() {
  printf '%s/design-reviewed-%s--%s' "$(claude_flag_dir)" "${1:-}" "$(flag_safe_branch "${2:-}")"
}

# transcript_path / session_id からコンテキストキーを導出する。
flag_ctx_key() {
  local raw="${1:-}"
  [[ -z "$raw" ]] && return 0
  basename -- "${raw%.jsonl}" 2>/dev/null || true
}

cs_injected_flag() {
  printf '%s/cs-injected-%s--%s' "$(claude_flag_dir)" "${1:-}" "${2:-}"
}

# rearm(clear|compact)が ctx 配下の全 scope を glob 削除するための接頭辞。
# 使い方: rm -f "$(cs_injected_flag_prefix "$ctx")"*
cs_injected_flag_prefix() {
  printf '%s/cs-injected-%s--' "$(claude_flag_dir)" "${1:-}"
}

# ── 設計レビューゲート(Phase 4)のキー ──
# ctx 版のキーは session_id(subagent と共有される性質を利用し、同一セッションの
# delegate worktree を自然にカバーする。Decisions: Phase4設計レビューゲートの3判断)。
# pending 版はモデル側(skill)が session_id を知れないための昇格用中間フラグ:
# skill が pending を書き、次の Gate 評価が自セッションの ctx 版へ取り込む。
# ctx 版はディスパッチャに載せない(sid は hook だけが知る値で、モデル側から
# 直接組み立てさせない設計)。

# session_id を path 安全化する(外部入力なので / と .. を branch と同様に無害化)。
flag_safe_ctx() {
  local c="${1:-}"
  c="${c//\//-}"
  c="${c//../_}"
  printf '%s' "$c"
}

design_reviewed_ctx_flag() {
  printf '%s/design-reviewed-ctx-%s--%s' "$(claude_flag_dir)" "${1:-}" "$(flag_safe_ctx "${2:-}")"
}

design_reviewed_pending_flag() {
  printf '%s/design-reviewed-pending-%s' "$(claude_flag_dir)" "${1:-}"
}

trivial_override_ctx_flag() {
  printf '%s/trivial-override-ctx-%s--%s' "$(claude_flag_dir)" "${1:-}" "$(flag_safe_ctx "${2:-}")"
}

trivial_override_pending_flag() {
  printf '%s/trivial-override-pending-%s' "$(claude_flag_dir)" "${1:-}"
}

# Tier 3(スコープ乖離)用: design-review が通した Plan の宣言スコープ(1行1 path/glob)。
design_scope_flag() {
  printf '%s/design-scope-%s--%s' "$(claude_flag_dir)" "${1:-}" "$(flag_safe_branch "${2:-}")"
}

design_scope_pending_flag() {
  printf '%s/design-scope-pending-%s' "$(claude_flag_dir)" "${1:-}"
}

# 直接実行(SKILL 等の非 source 文脈)用ディスパッチャ。
#   flag-paths.sh review-passed <repo_key> <branch>
#   flag-paths.sh design-reviewed <repo_key> <branch>
#   flag-paths.sh design-reviewed-pending <repo_key>
#   flag-paths.sh trivial-override-pending <repo_key>
#   flag-paths.sh design-scope <repo_key> <branch>
#   flag-paths.sh design-scope-pending <repo_key>
#   flag-paths.sh cs-injected <ctx> <scope>
#   flag-paths.sh dir
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  set -euo pipefail
  case "${1:-}" in
  review-passed) review_passed_flag "${2:-}" "${3:-}" ;;
  design-reviewed) design_reviewed_flag "${2:-}" "${3:-}" ;;
  design-reviewed-pending) design_reviewed_pending_flag "${2:-}" ;;
  trivial-override-pending) trivial_override_pending_flag "${2:-}" ;;
  design-scope) design_scope_flag "${2:-}" "${3:-}" ;;
  design-scope-pending) design_scope_pending_flag "${2:-}" ;;
  cs-injected) cs_injected_flag "${2:-}" "${3:-}" ;;
  dir) claude_flag_dir ;;
  *)
    cat >&2 <<'USAGE'
Usage: flag-paths.sh <subcommand> <args>
  review-passed            <repo_key> <branch>
  design-reviewed          <repo_key> <branch>
  design-scope             <repo_key> <branch>
  design-reviewed-pending  <repo_key>
  trivial-override-pending <repo_key>
  design-scope-pending     <repo_key>
  cs-injected              <ctx> <scope>
  dir
USAGE
    exit 1
    ;;
  esac
  printf '\n'
fi
