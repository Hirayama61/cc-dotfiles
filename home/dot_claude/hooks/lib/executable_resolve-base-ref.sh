#!/usr/bin/env bash
# resolve-base-ref.sh — 保護ブランチ一覧と「最近接の保護祖先」(diff 基点 base-ref)の
# 単一情報源(参謀ゲート Phase 1)。
#
# 背景: 保護ブランチ一覧(main/master/develop/epic/*)は従来 block-protected-branch-push /
# pre-push-selfreview-gate / ciwatch-on-push-nudge の3 hook にインライン三重持ちで drift
# リスクがあった。また消失検知(Tier 1 以降)は `git diff <base>...HEAD` の base を必要と
# する。両者をここへ集約し、各 hook / skill は source して使う。
#
# resolve_base_ref の導出規則:
#   1. PR target 起点: 対象 dir の現在ブランチに open PR があれば baseRefName を採用
#      (origin/<base> が ref として実在すれば優先)。stacked PR でも PR 宣言が権威なので
#      保護判定は課さない。
#   2. 無ければ保護ブランチ各々(origin/<name> と <name> の実在 ref・epic/* は実 ref を
#      列挙)と HEAD の merge-base を取り、**最近接**(HEAD から merge-base までの
#      コミット数 `rev-list --count <mb>..HEAD` が最小)の ref を返す。merge-base 自体の
#      root からの深さで比べると複数 root・複雑なマージ履歴で HEAD から遠い base を
#      選びうる。同距離は列挙順(origin 優先)で先勝ち。
#   3. どれも解決できなければ空を返す(fail-open。呼び出し側が判定を skip する)。
#
# 出力は ref 名(例: origin/main / epic/foo)。SHA でなく ref 名なので、呼び出し側は
# `git diff <ref>...HEAD` の三点記法にそのまま使える。
#
# gh 呼び出し(手順1)はネットワークを伴うため、PreToolUse のホットパスでは使わず
# self-review 等の重い文脈からだけ呼ぶこと。is_protected_branch は純関数で常時安全。
#
# bash 3.2 互換・source 時に set 状態を汚染しない・fail-open は resolve-git-target.sh /
# resolve-repo-key.sh と同作法。strict 化は直接実行ガード内でのみ行う。

# 保護ブランチ判定の単一情報源。一覧を変える時はここだけを変える。
is_protected_branch() {
  case "${1:-}" in
  main | master | develop | epic/*) return 0 ;;
  esac
  return 1
}

# 保護ブランチに対応する実在 ref を優先順(origin が先)で列挙する。1行1 ref。
# epic/* はパターンなので for-each-ref で実 ref に展開する。for-each-ref は複数
# パターンを1呼出に渡すと refname 順に混ぜて返す(origin 優先にならない)ため、
# remote / local を別呼出にして列挙順で優先を表現する。
_base_candidate_refs() {
  local dir="${1:-.}" name
  for name in main master develop; do
    if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$name" 2>/dev/null; then
      printf 'origin/%s\n' "$name"
    fi
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$name" 2>/dev/null; then
      printf '%s\n' "$name"
    fi
  done
  git -C "$dir" for-each-ref --format='%(refname:short)' 'refs/remotes/origin/epic/*' 2>/dev/null || true
  git -C "$dir" for-each-ref --format='%(refname:short)' 'refs/heads/epic/*' 2>/dev/null || true
  return 0
}

# 最近接の保護祖先 ref を stdout に返す(改行なし)。解決不能なら空(fail-open)。
resolve_base_ref() {
  local dir="${1:-.}"
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  # 1) PR target 起点。PR 無し / gh 不在 / 未認証はすべて空に倒して手順2へ。
  local pr_base=""
  if command -v gh >/dev/null 2>&1; then
    pr_base="$( (cd "$dir" 2>/dev/null && gh pr view --json baseRefName --jq .baseRefName) 2>/dev/null || true)"
  fi
  # baseRefName は fork PR 等で外部が命名しうる値。ref 名として不正なら捨てる
  # (戻り値は下流で git 引数に使われるため)。
  if [[ -n "$pr_base" ]] && ! git check-ref-format "refs/heads/$pr_base" 2>/dev/null; then
    pr_base=""
  fi
  if [[ -n "$pr_base" && "$pr_base" != "null" ]]; then
    if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$pr_base" 2>/dev/null; then
      printf 'origin/%s' "$pr_base"
      return 0
    fi
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$pr_base" 2>/dev/null; then
      printf '%s' "$pr_base"
      return 0
    fi
    # PR base がローカルに未 fetch なら merge-base フォールバックへ落ちる。
  fi

  # 2) 保護ブランチ各々との merge-base で最近接(HEAD からの距離最小)を選ぶ。
  local best_ref="" best_dist=-1
  local ref mb dist
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    mb="$(git -C "$dir" merge-base HEAD "$ref" 2>/dev/null || true)"
    [[ -z "$mb" ]] && continue
    dist="$(git -C "$dir" rev-list --count "$mb..HEAD" 2>/dev/null || true)"
    [[ -z "$dist" ]] && continue
    if [[ "$best_dist" -lt 0 || "$dist" -lt "$best_dist" ]]; then
      best_dist="$dist"
      best_ref="$ref"
    fi
  done < <(_base_candidate_refs "$dir")

  printf '%s' "$best_ref"
  return 0
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  set -euo pipefail
  resolve_base_ref "${1:-$PWD}"
  printf '\n'
fi
