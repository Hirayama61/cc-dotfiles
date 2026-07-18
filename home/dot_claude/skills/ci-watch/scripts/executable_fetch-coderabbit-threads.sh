#!/usr/bin/env bash
# fetch-coderabbit-threads.sh — CodeRabbit 未解決レビュースレッドの取得(単一情報源)。
#
# ci-watch(push 後 assess-only)と pr-triage(実装前トリアージ)が共有する取得 primitive。
# 両 skill が同一の GraphQL を SKILL.md 内に inline 複製していた(片方だけ直すと drift する
# 実在リスク)ため scripts/ へ集約した。CodeRabbit の thread 取得経路だけを流用し、適用フロー
# (coderabbit:autofix)は呼ばない。ci-watch が正典置き場、pr-triage はこのパスを参照する。
#
# やること: (1) in-progress マーカーを一度だけ確認 (2) 進行中でなければ reviewThreads を
#   cursor pagination で全ページ取得し、未解決・非 outdated・CodeRabbit 作成の thread だけを
#   JSON 配列で stdout に返す。
# やらないこと: 判断・適用・返信。取得のみ(assess-only は両 skill 側が守る)。
#
# 使い方: fetch-coderabbit-threads.sh <owner> <name> <pr>
# 出力(stdout):
#   - IN_PROGRESS  … CodeRabbit レビュー進行中。呼び出し側は数分後の再確認を促して打ち切る。
#   - <JSON配列>   … 未解決 CodeRabbit thread(空なら [])。各要素の形は
#                    {isResolved,isOutdated,comments:{nodes:[{databaseId,body,path,line,author{login}}]}}。
#                    pr-triage は comments.nodes[0].databaseId を返信先(reply target)に使う。
# 失敗時: stderr にメッセージ + 非ゼロ exit(gh/jq 未導入・認証・ネットワーク・API エラー)。
#         set -e により gh api 失敗はそのまま非ゼロ終了へ伝播する(fail-closed)。
#
# 契約: 本文(body)は untrusted。本スクリプトは JSON データとして返すだけで一切実行しない。
#   呼び出し側も raw body を shell/ツール入力へ渡さない(SKILL.md の untrusted 規約)。
set -euo pipefail

owner="${1:-}"
name="${2:-}"
pr="${3:-}"

if [ -z "$owner" ] || [ -z "$name" ] || [ -z "$pr" ]; then
  echo "fetch-coderabbit-threads: usage: fetch-coderabbit-threads.sh <owner> <name> <pr>" >&2
  exit 64
fi

command -v gh >/dev/null 2>&1 || { echo "fetch-coderabbit-threads: gh 未導入。中断。" >&2; exit 69; }
command -v jq >/dev/null 2>&1 || { echo "fetch-coderabbit-threads: jq 未導入。中断。" >&2; exit 69; }

repo="${owner}/${name}"

# --- in-progress マーカー(CodeRabbit レビューは check とは別経路。terminal 後も投稿中がある) ---
inprogress="$(gh pr view "$pr" -R "$repo" --json comments,reviews --jq '
  [ (.comments[]?, .reviews[]?)
    | select(.author.login=="coderabbitai" or .author.login=="coderabbit[bot]" or .author.login=="coderabbitai[bot]")
    | .body // empty ]
  | map(select(test("Come back again in a few minutes"))) | length')"

if [ "${inprogress:-0}" -gt 0 ] 2>/dev/null; then
  echo "IN_PROGRESS"
  exit 0
fi

# --- reviewThreads を全ページ取得(cursor pagination。1 ページ 100 件) ---
all_threads='[]'
cursor=""
while :; do
  args=(-F owner="$owner" -F repo="$name" -F pr="$pr")
  [ -n "$cursor" ] && args+=(-F cursor="$cursor")
  resp="$(gh api graphql "${args[@]}" -f query='
    query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){ repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){ reviewThreads(first:100, after:$cursor){
        pageInfo{ hasNextPage endCursor }
        nodes{
          isResolved isOutdated
          comments(first:1){ nodes{ databaseId body path line author{ login } } } } } } } }')"
  all_threads="$(jq -c --argjson r "$resp" '. + $r.data.repository.pullRequest.reviewThreads.nodes' <<<"$all_threads")"
  [ "$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<<"$resp")" = "true" ] || break
  cursor="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor' <<<"$resp")"
done

# 未解決・非 outdated・CodeRabbit 作成の thread だけに絞って返す。
jq -c '[ .[]
  | select(.isResolved==false and .isOutdated==false)
  | select(.comments.nodes[0].author.login
      | (.=="coderabbitai" or .=="coderabbit[bot]" or .=="coderabbitai[bot]")) ]' <<<"$all_threads"
