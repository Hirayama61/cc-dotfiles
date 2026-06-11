#!/usr/bin/env bash
# scope-deviation-check.sh — 消失検知 Tier 3: スコープ乖離の所見表示
# (参謀ゲート Phase 4。self-review skill のプリステップ専用。**surface-only**)。
#
# Usage: scope-deviation-check.sh [<dir>]
#
# design-review が通した Plan の宣言スコープ(design-scope フラグ。1 行 1 path/glob)と
# 実 diff(merge-base → 作業ツリー)のファイル一覧を照合し、宣言外のファイルを
# 所見として表示する。散文 → ファイルの写像はファジーなので **ack ゲートに乗せない**
# (Tier 1/2 と違い人間 ack を要求しない。提示のみ=計画仕様)。
#
# スコープの読込順: design-scope-<repo>--<branch> → 無ければ
# design-scope-pending-<repo>(鮮度 24h 以内のみ。plan 時点で branch 不在だった場合)。
# glob は bash の case パターンで照合する(`dir/*` / `*.sh` / 完全一致)。
#
# 出力契約(機械解釈は最終行のみ):
#   TIER3-RESULT: DEVIATION files=<n> … 宣言外ファイルあり(所見。ack 不要)
#   TIER3-RESULT: OK(<理由>)          … 乖離なし
#   TIER3-RESULT: SKIP(<理由>)        … スコープ宣言なし・判定不能(常に無害)
#   exit code は常に 0。
set -uo pipefail

dir="${1:-$PWD}"

skip() {
  printf 'TIER3-RESULT: SKIP(%s)\n' "$1"
  exit 0
}

LIB_DIR="$HOME/.claude/hooks/lib"
for lib in resolve-base-ref.sh flag-paths.sh; do
  [[ -r "$LIB_DIR/$lib" ]] || skip "lib 不達: $lib"
  # shellcheck source=/dev/null
  ( . "$LIB_DIR/$lib" ) >/dev/null 2>&1 || skip "lib 破損: $lib"
  # shellcheck source=/dev/null
  . "$LIB_DIR/$lib" 2>/dev/null || skip "lib 読込失敗: $lib"
done
for fn in resolve_base_ref design_scope_flag design_scope_pending_flag; do
  type "$fn" >/dev/null 2>&1 || skip "lib 旧版: $fn 未定義"
done

git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || skip "git repo 外: $dir"

REPO_RESOLVER="$LIB_DIR/resolve-repo-key.sh"
repo=""
[[ -x "$REPO_RESOLVER" ]] && repo="$("$REPO_RESOLVER" "$dir" 2>/dev/null || true)"
[[ -z "$repo" ]] && skip "repo key 解決不能"

branch="$(git -C "$dir" branch --show-current 2>/dev/null || echo "")"
scope_file=""
if [[ -n "$branch" && -f "$(design_scope_flag "$repo" "$branch")" ]]; then
  scope_file="$(design_scope_flag "$repo" "$branch")"
else
  p="$(design_scope_pending_flag "$repo")"
  if [[ -f "$p" ]]; then
    # pending の鮮度は 24h(Gate の昇格 TTL 6h より長い)。Tier 3 は surface-only で
    # 誤参照の実害が表示ノイズに留まるため、見逃し側を減らす方に倒す意図的な差。
    mt="$(stat -f %m "$p" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    [[ "$mt" -le "$now" && $((now - mt)) -le 86400 ]] && scope_file="$p"
  fi
fi
[[ -z "$scope_file" ]] && skip "スコープ宣言なし(design-review 未実施 or 宣言なしで通過)"

base="$(resolve_base_ref "$dir")"
[[ -z "$base" ]] && skip "base 解決不能"
mb="$(git -C "$dir" merge-base "$base" HEAD 2>/dev/null || true)"
[[ -z "$mb" ]] && skip "merge-base 取得失敗"

printf 'TIER3: スコープ乖離(scope=%s, base=%s)\n' "$(basename -- "$scope_file")" "$base"

# パターンは一度だけ読み込む(ファイルごとの再読込を避ける)。
patterns=()
while IFS= read -r pat; do
  [[ -n "$pat" ]] && patterns+=("$pat")
done <"$scope_file"

deviation=0
# diff(tracked の変更)に加え untracked も照合する。新規ファイルの作成は
# スコープ乖離のまさに典型なのに diff --name-only には出ないため。
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  matched=0
  for pat in ${patterns[@]+"${patterns[@]}"}; do
    # shellcheck disable=SC2254  # pat は意図的に glob パターンとして展開する
    case "$f" in
    $pat) matched=1; break ;;
    esac
  done
  if [[ "$matched" -eq 0 ]]; then
    deviation=$((deviation + 1))
    printf '宣言外: %s\n' "$f"
  fi
done < <(
  {
    git -c core.quotePath=false -C "$dir" diff --name-only "$mb" -- 2>/dev/null
    git -c core.quotePath=false -C "$dir" ls-files --others --exclude-standard 2>/dev/null
  } | LC_ALL=C sort -u
)

if [[ "$deviation" -gt 0 ]]; then
  printf 'TIER3-RESULT: DEVIATION files=%s\n' "$deviation"
else
  printf 'TIER3-RESULT: OK(宣言スコープ内)\n'
fi
exit 0
