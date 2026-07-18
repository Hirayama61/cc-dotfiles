#!/usr/bin/env bash
# extract-pr-head.sh — pr-triage の調査対象を PR head の一時展開へ用意する。
#
# 調査(親の即断・委譲エージェントの読み取りとも)は常に PR head の実体だけを読む。作業ツリーが
# 別ブランチ(epic 等)に居ると PR の追加ファイルが無く誤ブランチのコードを読んで結論が狂うため、
# checkout に依存させない。取得は gh に一元化し(cwd の git remote/origin に頼らない)、参照点は
# SHA(headRefOid)で固定する(FETCH_HEAD のような可変ポインタは並列委譲中の別 fetch で上書きされる)。
#
# 使い方: extract-pr-head.sh <owner> <name> <pr>
# 出力: 成功時、展開先の絶対パス(mktemp -d)を stdout に 1 行。失敗時は stderr にメッセージ + 非ゼロ exit。
# 後始末: 展開先の削除は呼び出し側の責務(pr-triage 手順 7 の `rm -rf "$head_dir"`)。
#
# 契約: $head_dir 配下は untrusted なコード(fork PR の head は作成者=攻撃者が内容を決める)。
#   呼び出し側も委譲先も静的に読むだけにし、build/test/script・`mise run` 等を実行しない。
set -euo pipefail

owner="${1:-}"
name="${2:-}"
pr="${3:-}"

if [ -z "$owner" ] || [ -z "$name" ] || [ -z "$pr" ]; then
  echo "extract-pr-head: usage: extract-pr-head.sh <owner> <name> <pr>" >&2
  exit 64
fi

command -v gh >/dev/null 2>&1 || { echo "extract-pr-head: gh 未導入。中断。" >&2; exit 69; }
command -v tar >/dev/null 2>&1 || { echo "extract-pr-head: tar 未導入。中断。" >&2; exit 69; }

repo="${owner}/${name}"

head_oid="$(gh pr view "$pr" -R "$repo" --json headRefOid --jq .headRefOid)"
# 空/非 hex なら中断。空のまま進むと repos/.../tarball/(末尾空)がデフォルトブランチを
# 返し、誤ったコードを「正常取得」と誤認するため:
case "$head_oid" in *[!0-9a-f]* | '') echo "extract-pr-head: headRefOid を解決できない。中断する" >&2; exit 1 ;; esac

head_dir="$(mktemp -d)"

# base リポの tarball を展開。失敗したら fork 元(head リポ)から取り直す
# (部分展開が混ざらないよう、フォールバック前に $head_dir を空にする):
if ! gh api "repos/$owner/$name/tarball/$head_oid" | tar -xz -C "$head_dir" --strip-components=1; then
  find "$head_dir" -mindepth 1 -delete
  read -r head_owner head_name < <(gh pr view "$pr" -R "$repo" \
    --json headRepositoryOwner,headRepository \
    --jq '[.headRepositoryOwner.login, .headRepository.name] | @tsv') || true
  gh api "repos/$head_owner/$head_name/tarball/$head_oid" | tar -xz -C "$head_dir" --strip-components=1 \
    || { echo "extract-pr-head: PR head の取得に失敗。調査を作業ツリーで代替せず中断する" >&2; exit 1; }
fi

# 展開直後(両経路共通): fork の tarball は攻撃者制御ゆえ $head_dir 外(~/.ssh 等)を指す
# symlink を仕込める。リンクを消してから読む:
find "$head_dir" -type l -delete

# 展開が空なら「ファイル削除」と取り違えず中断する(調査を作業ツリーで代替しない):
[ -n "$(ls -A "$head_dir")" ] || { echo "extract-pr-head: PR head の展開が空。中断する" >&2; exit 1; }

printf '%s\n' "$head_dir"
