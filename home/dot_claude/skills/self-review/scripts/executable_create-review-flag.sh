#!/usr/bin/env bash
# create-review-flag.sh — self-review skill 手順 5 の review-passed フラグ作成を移設。
#
# Usage: create-review-flag.sh <tier1_lastline> <tier2_lastline> <reason1> <reason2>
#   stdin: findings JSONL(0 行以上。1 行 1 レコードの JSON オブジェクト)。
#          **この PR で直さなかった finding だけ**を入れる(直した分は記録対象外)。
#          triage 行は本スクリプトがここから生成する。呼び出し側に 1 行書式を手書きさせない
#          — 手書きさせると理由文中の区切り記号やクォートが行構造を壊す(意味判断は LLM、
#          構文と状態遷移はスクリプト、という境界)。
#   レビュー対象 repo 内($PWD = 対象 worktree)で呼ばれる前提。gate / postcommit は
#   フラグキーを push 実対象 dir 起点で引くため、別 cwd で実行するとキー基点がずれて
#   恒久ブロックになりうる。
#
# findings レコードの必須フィールド(語彙の正典は SKILL.md 手順 3):
#   id         "F-NNN"(F-001 からの連番・重複なし)
#   severity   重大 / 改善 / 情報
#   tags       配列。security / quality / perf / test / slop / arch / guide のいずれか 1 つ以上
#   confidence 高 / 中 / 低 / 未申告
#   judgment   必須 / 要確認 / 推奨 / 任意 / 既存 / 見送り可
#   reason     非空の自由文
#   evidence   judgment=既存 のとき必須(base 側の裏取り根拠)。他は任意
#   disposition 任意。人間が 4b で決めた処置("見送る" / "今すぐ修正")
#
# gate 判定(fail-closed。1 つでも該当すればフラグを作らない):
#   - judgment が 必須 / 要確認 のまま disposition が "見送る" でないレコードがある
#     (= 直すべきものが残っている、または人間の判断待ち)
#   - disposition が "今すぐ修正" のレコードがある(人間が blocker と決めた)
#   - 語彙違反・必須フィールド欠落・id の連番/重複違反・JSONL として読めない
#   - jq が無い(検証できないなら作らない)
#
# 界面は固定(Tier 判定を再実行しない)。tierN_lastline は skill 手順 1.5 で捕捉した各 Tier
# 出力の最終行、reasonN は 4b で人間が述べた ack 理由(非該当なら空文字)。
#
# フラグの書き方: 1 行目に `head: <現 HEAD>` を書き、その後に 4b で集めた Tier ack 理由 +
# triage 行を記録する。gate はこの 1 行目を push 対象の HEAD と突き合わせるので、HEAD が
# 動いたフラグは自動的に無効になる(書式の正典は flag-paths.sh)。ack 理由は改行を潰して
# 1 行に収める(後続行に偽の head 行を作らせない)。該当 Tier の理由が空ならフラグを書かず
# 中断する(空理由での素通り防止)。既存フラグは子/別経路の自力作成を疑う異常として中断する
# (陳腐フラグでも置換しない。中断メッセージにパスを出すので、陳腐なら人手で消してから再実行)。
# 作成は同 dir の一時ファイルへ書き込み → ln(ハードリンク)で原子的に配置する(宛先が既存なら
# ln が失敗する=noclobber 等価)。失敗時は一時ファイルのみ消して中断し、既存フラグは巻き添え
# 削除しない(競合相手の正当フラグを守る + 残骸での誤解除を防ぐ)。
#
# フラグキーは flag-paths.sh が単一情報源。gate(読取)/ postcommit(削除)も同 lib を使うため
# 必ず lib 経由で得る。repo は resolve-repo-key.sh で導出。
set -uo pipefail

tier1_lastline="${1-}"
tier2_lastline="${2-}"
reason1="${3-}"
reason2="${4-}"

# ack 理由は人間の自由文なので、改行・CR を空白へ潰してから 1 行として記録する
# (フラグの行構造を壊させない = 後続行に偽の head 行を作らせない)。
oneline() { printf '%s' "${1-}" | tr '\n\r' '  '; }

# findings JSONL を読み切り、検証してから triage 行を生成する。
# 生成側で `triage: ` を前置し、値の改行・CR は空白へ潰す(後続行に偽の head 行を作らせない)。
findings_in="$(cat)"
triage_out=""

if printf '%s' "$findings_in" | grep -q '[^[:space:]]'; then
  command -v jq >/dev/null 2>&1 \
    || { echo "jq が無く findings を検証できない。フラグは作らない(fail-closed)。中断" >&2; exit 1; }

  findings_json="$(printf '%s\n' "$findings_in" | jq -s '.' 2>/dev/null)" \
    || { echo "findings が JSONL として読めない(1 行 1 レコードの JSON オブジェクト)。中断" >&2; exit 1; }

  # 語彙・必須フィールド・連番・gate 条件をまとめて検査する。1 件 1 行のエラーを出し、
  # 非空なら中断する(どれか 1 つでも通らなければフラグを作らない)。
  findings_errs="$(printf '%s' "$findings_json" | jq -r '
    def sev: ["重大","改善","情報"];
    def conf: ["高","中","低","未申告"];
    def judg: ["必須","要確認","推奨","任意","既存","見送り可"];
    def blocking: ["必須","要確認"];
    def tagv: ["security","quality","perf","test","slop","arch","guide"];

    ( to_entries[]
      | (.key + 1) as $n
      | .value as $f
      | if ($f | type) != "object" then "レコード \($n): JSON オブジェクトでない"
        else
          ( if (($f.id // "") | tostring | test("^F-[0-9]{3}$")) then empty
            else "レコード \($n): id が F-NNN 形式でない" end ),
          ( if (sev | index($f.severity // "")) then empty
            else "レコード \($n): severity が語彙外(\($f.severity // "なし"))" end ),
          ( if (conf | index($f.confidence // "")) then empty
            else "レコード \($n): confidence が語彙外(\($f.confidence // "なし"))" end ),
          ( if (judg | index($f.judgment // "")) then empty
            else "レコード \($n): judgment が語彙外(\($f.judgment // "なし"))" end ),
          ( if (($f.tags // null) | type) != "array" then "レコード \($n): tags が配列でない"
            elif ($f.tags | length) == 0 then "レコード \($n): tags が空"
            elif ($f.tags | all(. as $t | tagv | index($t) != null)) | not then
              "レコード \($n): tags に語彙外の値"
            else empty end ),
          ( if (($f.reason // "") | tostring | length) > 0 then empty
            else "レコード \($n): reason が空" end ),
          ( if ($f.judgment == "既存") and ((($f.evidence // "") | tostring | length) == 0) then
              "レコード \($n) (\($f.id // "?")): judgment=既存 に evidence(base 側の裏取り根拠)が無い"
            else empty end ),
          ( if ($f.disposition // "") == "今すぐ修正" then
              "レコード \($n) (\($f.id // "?")): 人間が今すぐ修正と決めた blocker が残っている"
            else empty end ),
          ( if (blocking | index($f.judgment // "")) and (($f.disposition // "") != "見送る") then
              "レコード \($n) (\($f.id // "?")): judgment=\($f.judgment) が未決着(人間が見送ると決めた場合のみ disposition=見送る で通す)"
            else empty end )
        end ),
    ( [ .[] | if type == "object" then (.id // "") else "" end ] as $ids
      | ( if ($ids | length) != ($ids | unique | length) then "id が重複している" else empty end ),
        ( if $ids == [ range(1; ($ids | length) + 1) | "F-" + (("00" + tostring) | .[-3:]) ]
          then empty else "id が F-001 からの連番になっていない" end ) )
  ' 2>/dev/null)" \
    || { echo "findings の検証に失敗(jq)。中断" >&2; exit 1; }

  if [ -n "$findings_errs" ]; then
    echo "findings が検証を通らないためフラグを作らない:" >&2
    printf '%s\n' "$findings_errs" >&2
    exit 1
  fi

  triage_out="$(printf '%s' "$findings_json" | jq -r '
    def oneline: tostring | gsub("[\n\r]"; " ");
    .[]
    | "triage: \(.id) [\(.severity)/\(.tags | join(","))] 確信度:\(.confidence) \(.judgment)"
      + (if (.disposition // "") != "" then "(人間: \(.disposition | oneline))" else "" end)
      + " — \(.reason | oneline)"
      + (if (.evidence // "") != "" then " / 裏取り: \(.evidence | oneline)" else "" end)
  ' 2>/dev/null)" \
    || { echo "triage 行の生成に失敗(jq)。中断" >&2; exit 1; }
  if [ -n "$triage_out" ]; then triage_out="${triage_out}"$'\n'; fi
fi

LIB_DIR="$HOME/.claude/hooks/lib"

# branch は resolve-repo-key.sh(repo 導出)と基点を統一するため git -C "$PWD" で引く。
branch="$(git -C "$PWD" branch --show-current)"
repo="$("$LIB_DIR/resolve-repo-key.sh" "$PWD" 2>/dev/null || true)"
# repo / branch の空は無効キーのフラグを作らせないため個別に拒否する。
[ -n "$repo" ] || { echo "repo キーが空。中断" >&2; exit 1; }
[ -n "$branch" ] || { echo "branch が空。中断" >&2; exit 1; }
flag="$("$LIB_DIR/flag-paths.sh" review-passed "$repo" "$branch")"
[ -n "$flag" ] || { echo "flag-paths.sh が引けない。中断" >&2; exit 1; }

# レビュー対象の HEAD。引けない(コミットの無いブランチ)なら束縛できないのでフラグを書かない。
# `rev-parse HEAD` は解決に失敗しても stdout に "HEAD" をそのまま出すので、空判定が効かない。
# --verify --quiet + ^{commit} なら失敗時に何も出さない。
head_sha="$(git -C "$PWD" rev-parse --verify --quiet "HEAD^{commit}" 2>/dev/null || true)"
[ -n "$head_sha" ] || { echo "HEAD が引けない(コミットの無いブランチか非 repo)。中断" >&2; exit 1; }
# 版ずれ(lib が古く head 行を作れない)なら書かない。フラグ不在は gate がブロックするので
# fail-closed 方向で安全。
head_line="$("$LIB_DIR/flag-paths.sh" review-head-line "$head_sha" 2>/dev/null || true)"
case "$head_line" in
*"$head_sha") : ;;
*) echo "flag-paths.sh が head 行を作れない(lib が古い)。mise run apply:cc-dotfiles 後に再実行。中断" >&2; exit 1 ;;
esac
"$LIB_DIR/flag-paths.sh" dir-ensure \
  || { echo "flag state dir の検証に失敗。中断" >&2; exit 1; }

# Tier 連結の非空チェックは片方の理由だけで素通りするため、該当 Tier ごとに理由必須を個別検証。
# tierN_lastline は呼び出し側が最終行を渡す界面だが、呼び出し側依存を排するため grep 前に
# 自衛の tail -n1 を掛ける(fail-closed 方向は不変: 余分な行があっても最終行のみで判定)。
if printf '%s\n' "$tier1_lastline" | tail -n1 | grep -q '^TIER1-RESULT: DECREASE' \
  && [ -z "$reason1" ]; then
  echo "Tier 1 DECREASE の ack 理由が空。中断" >&2; exit 1
fi
if printf '%s\n' "$tier2_lastline" | tail -n1 | grep -q '^TIER2-RESULT: RESURRECT' \
  && [ -z "$reason2" ]; then
  echo "Tier 2 RESURRECT の ack 理由が空。中断" >&2; exit 1
fi

# 既存は手順 2b(子 reviewer read-only)を破った自力作成を疑う異常として中断。HEAD が commit
# 以外で動いた後の陳腐フラグもここに来る(置換はしない)。何を消せばよいか分かるよう、記録
# head と現 HEAD とフラグのパスを出す。
if [ -e "$flag" ]; then
  existing_head="$("$LIB_DIR/flag-paths.sh" review-head-of "$flag" 2>/dev/null || true)"
  echo "想定外: review-passed フラグが既存(記録 head=${existing_head:-なし} / 現 HEAD=$head_sha)。子/別経路の自力作成、または HEAD が commit 以外で動いた後の陳腐フラグ。中断: $flag" >&2
  exit 1
fi

# 同 dir の一時ファイルへ書き込み → ln(ハードリンク)で原子的に配置する。ln は宛先が既存なら
# 失敗する(noclobber 等価)ので、[ -e ] 後の窓で競合作成されても既存を壊さない。失敗時に
# 既存フラグを rm しないのは、競合相手の正当フラグを巻き添え削除しないため。1 行目の head 行は
# 必ず書き、ack/見送り理由があればその後に続ける(該当ゼロなら head 行 1 行のフラグになる)。
tmp="$flag.tmp.$$"
{
  printf '%s\n' "$head_line"
  if [ -n "$reason1" ]; then printf 'tier1-ack: %s\n' "$(oneline "$reason1")"; fi
  if [ -n "$reason2" ]; then printf 'tier2-ack: %s\n' "$(oneline "$reason2")"; fi
  if [ -n "$triage_out" ]; then printf '%s' "$triage_out"; fi
} > "$tmp" 2>/dev/null \
  || { rm -f "$tmp"; echo "review-passed フラグの作成に失敗(一時ファイル書込)。中断" >&2; exit 1; }

if ln "$tmp" "$flag" 2>/dev/null; then
  rm -f "$tmp"
else
  rm -f "$tmp"
  echo "review-passed フラグの作成に失敗(既存/権限/state dir)。中断" >&2
  exit 1
fi

exit 0
