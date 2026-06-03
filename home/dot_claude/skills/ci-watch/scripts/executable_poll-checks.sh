#!/usr/bin/env bash
# poll-checks.sh — ci-watch のゼロトークン bg 待機スクリプト。
#
# ci-watch skill が Bash ツール `run_in_background:true` で起動する(hook ではない)。
# 指定 PR の全 check が terminal(pass/fail/skipping/cancel)になるまで自前ループで待ち、
# 最終状態サマリを stdout に出して exit する。bg プロセスの exit で harness が Claude を
# 起床させ、ci-watch が評価フェーズへ進む。待機中は Claude のトークンを一切消費しない。
#
# 設計の核(Decisions/2026-06-04-ci-watchをhook自動起動のCodeRabbit評価専用skillに再設計):
#   - hook は注入だけ。ポーリングは Claude が bg Bash ツールで起動(harness 起床のため)。
#   - macOS に GNU `timeout` が無い(Knowledge/macOSにtimeoutコマンドが無い)ので
#     `timeout` に依存せず自前カウンタ + sleep で上限を設ける。
#   - bash 3.2 互換(macOS 既定): 連想配列を使わない・集計は jq 側・set -u 下の空配列展開を避ける。
#   - 冪等化: atomic mkdir lock(macOS に flock 無し)で同一 PR の二重 watch を防ぐ。
#     stale lock は lock dir 内 PID を kill -0 で生存確認し、死んでいれば奪取する。
#   - CodeRabbit 完了は終了条件にしない(gh pr checks の terminal のみ)。CodeRabbit thread の
#     有無は起床後に ci-watch 本体が一度だけ確認する(Decisions #6)。
#
# 使い方: poll-checks.sh <PR番号> [interval秒=30] [max試行回数=30]  (既定 = 30s×30 = 15分上限)
# 出力: 最終状態(全 check の name/bucket/state)+ 判定行(ALL_TERMINAL / TIMEOUT / NO_CHECKS)。
set -euo pipefail

pr="${1:-}"
repo="${2:-}"
interval="${3:-30}"
max="${4:-30}"

if [ -z "$pr" ]; then
  echo "poll-checks: PR 番号が必要(usage: poll-checks.sh <PR> [owner/repo] [interval] [max])" >&2
  exit 64
fi

command -v gh >/dev/null 2>&1 || { echo "poll-checks: gh 未導入。中断。" >&2; exit 69; }
command -v jq >/dev/null 2>&1 || { echo "poll-checks: jq 未導入。中断。" >&2; exit 69; }

# repo を明示引数(owner/repo)で受け、全 gh 呼び出しを -R "$repo" で固定する。
# これがないと bg Bash は $PWD(dispatcher 運用では primary repo)で gh が走り、別 repo の
# 同名 PR を誤って監視しうる(F-002 と同根が poll-checks に残っていた指摘)。-R は cwd 不問で
# 堅い(repo_dir+cd より cwd 依存を完全に断てる)。空なら $PWD フォールバック(手動・後方互換)。
GH_R=()
if [ -n "$repo" ]; then
  GH_R=(-R "$repo")
fi

# --- repo キー(lock 命名用)。repo 引数があればそれから導出($PWD 非依存)。無ければ $PWD 代替 ---
# repo 名 basename にする(owner/ を落とす)。resolve-repo-key / common-dir フォールバックも
# basename(= cc-dotfiles)を返すので、hook 経由(repo 引数あり)と手動 /ci-watch(repo 引数なし
# → フォールバック)が同一 PR で同一 lock_dir になり二重 watch を確実に防げる(PR #18 再レビュー D)。
repo_key=""
if [ -n "$repo" ]; then
  repo_key="${repo##*/}"
fi
if [ -z "$repo_key" ]; then
  RESOLVER="$HOME/.claude/hooks/lib/resolve-repo-key.sh"
  if [ -x "$RESOLVER" ]; then
    repo_key="$("$RESOLVER" "$PWD" 2>/dev/null || true)"
  fi
fi
if [ -z "$repo_key" ]; then
  # フォールバック: common-dir 親の basename(worktree でも repo 名に解決)。
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$common_dir" ]; then
    case "$common_dir" in
    /*) ;;
    *) common_dir="$PWD/$common_dir" ;;
    esac
    repo_root="$(cd "$common_dir/.." 2>/dev/null && pwd -P || true)"
    [ -n "$repo_root" ] && repo_key="$(basename -- "$repo_root")"
  fi
fi
[ -n "$repo_key" ] || repo_key="unknown"

# --- atomic mkdir lock(同一 PR 二重 watch 防止。複数 PR は番号で分かれるので並行可) ---
lock_root="/tmp/claude-sessions"
mkdir -p "$lock_root"
lock_dir="${lock_root}/ci-watch-${repo_key}-pr${pr}"
pid_file="${lock_dir}/pid"

acquire_lock() {
  if mkdir "$lock_dir" 2>/dev/null; then
    echo "$$" >"$pid_file"
    return 0
  fi
  # 取得失敗 = 既存 lock。stale(プロセス死亡)なら奪取する。
  local old_pid=""
  [ -f "$pid_file" ] && old_pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    # 生存中 = 真の二重起動。起動しない。
    return 1
  fi
  # PID 不在 or 死亡 = stale。奪取(古い lock を作り直す)。
  rm -rf "$lock_dir" 2>/dev/null || true
  if mkdir "$lock_dir" 2>/dev/null; then
    echo "$$" >"$pid_file"
    return 0
  fi
  # 競合(同時奪取)で負けた = 他が watch 中とみなす。
  return 1
}

if ! acquire_lock; then
  echo "poll-checks: PR #${pr} は既に watch 中(${lock_dir})。二重起動しない。"
  echo "ALREADY_WATCHING"
  exit 0
fi

# lock は正常/異常どちらの終了でも解放する。
cleanup() { rm -rf "$lock_dir" 2>/dev/null || true; }
trap cleanup EXIT

# --- 全 check が terminal か判定。check 0 件は terminal 扱い(非 Actions リポの自動 no-op) ---
# bucket は gh が state を pass/fail/pending/skipping/cancel に分類する。
# terminal = pending 以外(pending だけが進行中)。0 件は「待つものが無い」= terminal。
# 失敗時(API エラー等)は -1 を返し、呼び出し側で「不明=待つ」に倒す(false-terminal 回避)。
pending_count() {
  local out
  # "${GH_R[@]+...}" は bash 3.2 + set -u で空配列展開が unbound にならないためのガード。
  out="$(gh pr checks "$pr" "${GH_R[@]+"${GH_R[@]}"}" --json bucket 2>/dev/null || echo "__ERR__")"
  if [ "$out" = "__ERR__" ]; then
    echo "-1"
    return 0
  fi
  # gh は check 0 件のとき空配列 [] を返す → pending 0 → terminal 扱い。
  printf '%s' "$out" | jq -r '[ .[] | select(.bucket=="pending") ] | length' 2>/dev/null || echo "-1"
}

# --- メインループ(timeout 不使用・自前カウンタ + sleep) ---
i=0
result="TIMEOUT"
while [ "$i" -lt "$max" ]; do
  pc="$(pending_count)"
  if [ "$pc" = "0" ]; then
    result="ALL_TERMINAL"
    break
  fi
  # pc = -1 (取得失敗/不明) は「待つ」に倒す(false-terminal で早期起床させない)。
  i=$((i + 1))
  [ "$i" -lt "$max" ] && sleep "$interval"
done

# --- 最終状態サマリ ---
echo "=== ci-watch poll result: PR #${pr} (repo=${repo_key}) ==="
final="$(gh pr checks "$pr" "${GH_R[@]+"${GH_R[@]}"}" --json name,bucket,state,link 2>/dev/null || echo "__ERR__")"
if [ "$final" = "__ERR__" ]; then
  echo "checks 取得失敗(API エラー / 認証 / PR 不在)。手動で gh pr checks ${pr}${repo:+ -R $repo} を確認。"
  echo "FETCH_ERROR"
  exit 0
fi

total="$(printf '%s' "$final" | jq -r 'length' 2>/dev/null || echo 0)"
if [ "$total" = "0" ]; then
  echo "check は 0 件(Actions 未設定 or required check 無し)。CI 失敗 triage は不要。"
  echo "NO_CHECKS"
  exit 0
fi

printf '%s' "$final" | jq -r '.[] | "  [\(.bucket)] \(.name) (state=\(.state))"' 2>/dev/null || true
fail_count="$(printf '%s' "$final" | jq -r '[ .[] | select(.bucket=="fail") ] | length' 2>/dev/null || echo 0)"
echo "総 check=${total} / 失敗(fail)=${fail_count} / 経過試行=${i}/${max}(interval=${interval}s)"
# 説明文は判定トークンより前に出す。SKILL.md の「最終行=判定トークン」契約を全分岐で守るため
# (ALL_TERMINAL / NO_CHECKS / FETCH_ERROR / TIMEOUT いずれも最終行が判定。PR #18 再レビュー E)。
if [ "$result" = "TIMEOUT" ]; then
  echo "(上限 ${max}×${interval}s に到達。未確定の check が残っている可能性。打ち切り。)"
fi
echo "$result"
exit 0
