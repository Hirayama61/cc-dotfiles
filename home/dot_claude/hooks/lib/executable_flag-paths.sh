#!/usr/bin/env bash
# flag-paths.sh — ゲートフラグの state dir 提供 + キー導出規約の単一情報源
# (参謀ゲート Phase 1、state dir 移行 #49)。
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
#   evolve-nudged-${ctx}                             (ローカル進化ナッジ: 1 ctx 1 回)
#   decision-nudged-${ctx}                           (判断記録ナッジ: 1 ctx 1 回)
# safe_branch = branch を '/'→'-' サニタイズ + 元 branch の SHA-256 先頭16桁サフィックス
#   (不可逆置換による feature/a-b ≡ feature-a/b 衝突を解消。#49 B-1)。
# ctx = transcript_path(無ければ session_id)の basename から末尾 .jsonl を除去。
# repo_key は resolve-repo-key.sh、branch は push/commit 実対象 dir
# (resolve-git-target.sh)起点で得る(導出はここではしない)。
#
# bash 3.2 互換・source 時に set 状態を汚染しない・fail-open(空入力でもエラーに
# しない)は resolve-repo-key.sh と同作法。strict 化は直接実行ガード内でのみ行う。

# ゲートフラグの state dir。XDG_STATE_HOME 配下に置き /tmp 共有名前空間を脱する(#49 B-3)。
# XDG_STATE_HOME が絶対パスでなければ無視して $HOME/.local/state へ倒す(相対パスは呼び出し側
# cwd 依存で予測不能・別ユーザ書込の穴になるため)。
claude_flag_dir() {
  local base="${XDG_STATE_HOME:-}"
  case "$base" in
  /*) ;;
  *) base="$HOME/.local/state" ;;
  esac
  printf '%s/claude-sessions' "$base"
}

# state dir を 0700 で用意し、最終 dir が実ディレクトリ・非 symlink・自ユーザ所有・mode 0700 で
# あることを検証する。いずれか失敗で非ゼロ return(書込側は中止。読取側ゲートは fail-open のまま)。
# 全書込経路(hook の mark / design-gate の touch・mv / skill のフラグ作成 / ci-watch lock)は
# これを通してから書く。stdout には何も出さない(PreToolUse hook から呼ぶため出力で汚さない)。
# 注: これは「$HOME 配下の自分の dir」健全性チェックであり、TOCTOU 耐性や中間ディレクトリ
# (~/.local 等)の検証・中間 symlink 経由のリダイレクトは目標外。/tmp を脱した時点で攻撃面は
# 自アカウントに限定され、$HOME 配下に細工できる時点でアカウント陥落(ゲートの脅威モデル
# 「自分の Claude を縛る best-effort、敵対防御ではない」内)。
claude_flag_dir_ensure() {
  local dir
  dir="$(claude_flag_dir)"
  (umask 077 && mkdir -p "$dir") 2>/dev/null || return 1
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  local owner
  owner="$(stat -f '%u' "$dir" 2>/dev/null || printf '%s' -1)"
  [[ "$owner" == "$(id -u)" ]] || return 1
  chmod 700 "$dir" 2>/dev/null || return 1
  return 0
}

# branch を path 安全化 + 衝突回避サフィックス。'/'→'-' だけだと不可逆で feature/a-b と
# feature-a/b が同一キーに衝突し偽承認が成立する(#49 B-1)。元 branch バイト列の SHA-256
# 先頭16桁=64bit(macOS 標準 shasum)で一意化する。8桁=32bit はサニタイズ後同名化しうる
# ブランチ群で意図的衝突の余地が残るため 16 桁に増やす(CodeRabbit PR#63)。空入力は空のまま
# (現行同様 suffix 無し)。shasum 不在(macOS では実質起きない)は cksum(POSIX 常在)へ
# fallback し必ず suffix を付ける(旧 lossy 形へ戻さない=衝突を復活させない)。読取/書込が
# 本関数を共有するので両側一致する。
flag_safe_branch() {
  local raw="${1:-}"
  [[ -z "$raw" ]] && return 0
  local sanitized hash
  sanitized="$(printf '%s' "$raw" | tr '/' '-')"
  hash="$(printf '%s' "$raw" | shasum -a 256 2>/dev/null | cut -c1-16)"
  [[ -z "$hash" ]] && hash="$(printf '%s' "$raw" | cksum 2>/dev/null | cut -d' ' -f1)"
  printf '%s-%s' "$sanitized" "$hash"
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

# ローカル進化ナッジ(evolve-nudge-on-stop)の 1 ctx 1 回フラグ。ctx は cs-injected と
# 同じ flag_ctx_key 導出(transcript_path 基準)。rearm(clear|compact)で削除して再武装する。
evolve_nudged_flag() {
  printf '%s/evolve-nudged-%s' "$(claude_flag_dir)" "${1:-}"
}

# 判断記録ナッジ(capture-decision)の 1 ctx 1 回フラグ。ctx は cs-injected / evolve-nudged と
# 同じ flag_ctx_key 導出(transcript_path 基準)。rearm(clear|compact)で削除して再武装する。
decision_nudged_flag() {
  printf '%s/decision-nudged-%s' "$(claude_flag_dir)" "${1:-}"
}

# ── カウンタ機構(マーカーファイル数え上げ / 詰まり検知 P-5・委譲ナッジ P-6)──
# 既存フラグは存在/非存在のブール(review-passed / cs-injected / *-nudged 等)。
# 詰まり・委譲ナッジは「同種コマンドの連続失敗数」「探索ツールの ctx 累計」という数値を
# 持つ別機構だが、数値の read-modify-write(値を読んで +1 して書き戻す)は並列イベントで
# ロストアップデートする(複数プロセスが同じ値を読み同じ値を書く)。これを構造的に避けるため、
# カウント dir 内へイベントごとに mktemp で一意ファイルを atomic 作成し、カウント = ファイル数、
# リセット = dir 削除、とする(F-002)。ブールフラグ群とは別機構であることを関数構造で明示する。
# ナッジ発火の at-most-once は別途 claim ディレクトリ(*_nudged_flag を mkdir で atomic に取る)
# 側で保証する。

# カウント dir にマーカーを1つ atomic 追加し、現在のマーカー数を stdout に返す。
# dir を作れない/mktemp 失敗(書込不能)は 0(進めない=fail-open)。並列安全。
flag_counter_bump() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || {
    printf '0'
    return 0
  }
  mkdir -p "$dir" 2>/dev/null || {
    printf '0'
    return 0
  }
  mktemp "$dir/m.XXXXXXXX" >/dev/null 2>&1 || {
    printf '0'
    return 0
  }
  flag_counter_count "$dir"
}

# カウント dir 内のマーカー数を返す(dir 不在は 0)。
flag_counter_count() {
  local dir="${1:-}" n
  [[ -n "$dir" && -d "$dir" ]] || {
    printf '0'
    return 0
  }
  n="$(find "$dir" -type f 2>/dev/null | wc -l)"
  printf '%s' "$((n))"
}

# カウンタをリセット(dir ごと削除)。
flag_counter_reset() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || return 0
  rm -rf "$dir" 2>/dev/null || true
}

# 任意文字列を 16 桁(64bit)にハッシュ化する。コマンド種別をファイル名へ直接使わず
# キー化するのに使う(flag_safe_branch と同じ shasum→cksum フォールバック)。空入力は空のまま。
flag_hash16() {
  local raw="${1:-}" h
  [[ -z "$raw" ]] && return 0
  h="$(printf '%s' "$raw" | shasum -a 256 2>/dev/null | cut -c1-16)"
  [[ -z "$h" ]] && h="$(printf '%s' "$raw" | cksum 2>/dev/null | cut -d' ' -f1)"
  printf '%s' "$h"
}

# 詰まり検知(stuck-nudge)の種別ごと連続失敗カウント dir。第2引数は種別のハッシュ(flag_hash16)。
# 種別ごとに独立(別種の失敗はカウントを共有しない)。同種の成功でその種別の dir のみ削除。
stuck_count_dir() {
  printf '%s/stuck-count-%s--%s' "$(claude_flag_dir)" "${1:-}" "${2:-}"
}

# rearm(clear|compact)が ctx 配下の全種別カウント dir を glob 削除するための接頭辞。
# 使い方: rm -rf "$(stuck_count_dir_prefix "$ctx")"*
stuck_count_dir_prefix() {
  printf '%s/stuck-count-%s--' "$(claude_flag_dir)" "${1:-}"
}

# 詰まりナッジの 1 ctx 1 回 claim。ディレクトリ(mkdir で atomic に取得)で、存在=発火済み。
# 並列失敗でも mkdir に成功した最初の 1 プロセスだけがナッジを出す。
stuck_nudged_flag() {
  printf '%s/stuck-nudged-%s' "$(claude_flag_dir)" "${1:-}"
}

# 委譲ナッジ(delegation-nudge)の探索ツール(Grep/Glob)ctx 累計カウント dir。Agent 使用でリセット。
delegation_count_dir() {
  printf '%s/delegation-count-%s' "$(claude_flag_dir)" "${1:-}"
}

# 委譲ナッジの 1 ctx 1 回 claim(stuck_nudged_flag と同じディレクトリ claim 方式)。
delegation_nudged_flag() {
  printf '%s/delegation-nudged-%s' "$(claude_flag_dir)" "${1:-}"
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
#   flag-paths.sh stuck-count-dir <ctx> <kindhash>
#   flag-paths.sh stuck-nudged <ctx>
#   flag-paths.sh delegation-count-dir <ctx>
#   flag-paths.sh delegation-nudged <ctx>
#   flag-paths.sh hash16 <string>
#   flag-paths.sh dir
#   flag-paths.sh dir-ensure          (非 source 文脈から state dir を 0700 で用意・検証)
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
  stuck-count-dir) stuck_count_dir "${2:-}" "${3:-}" ;;
  stuck-nudged) stuck_nudged_flag "${2:-}" ;;
  delegation-count-dir) delegation_count_dir "${2:-}" ;;
  delegation-nudged) delegation_nudged_flag "${2:-}" ;;
  hash16) flag_hash16 "${2:-}" ;;
  dir) claude_flag_dir ;;
  dir-ensure) claude_flag_dir_ensure || exit 1; exit 0 ;;
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
  stuck-count-dir          <ctx> <kindhash>
  stuck-nudged             <ctx>
  delegation-count-dir     <ctx>
  delegation-nudged        <ctx>
  hash16                   <string>
  dir
  dir-ensure
USAGE
    exit 1
    ;;
  esac
  printf '\n'
fi
