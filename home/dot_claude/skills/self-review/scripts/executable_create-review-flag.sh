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
#   id         "F-NNN"(重複なし。直した finding は入れないので番号は飛んでよい)
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
#   - tags に security があるのに judgment が 必須 / 要確認 / 既存 のどれでもない
#     (Rule R2 は [security] をこの 3 つのどれかへ倒す。素通りは判定の取り違え)
#   - 語彙違反(型違いを含む)・必須フィールド欠落・id 重複・1 行 1 オブジェクトでない
#   - 同一レコードに同じフィールド名が 2 回現れる(重複キーは後勝ちで判定を上書きする)
#   - judgment=既存 の evidence に裏取りコマンドの痕跡(git log / git blame / git show /
#     commit <sha>)が無い
#   - jq が無い(検証できないなら作らない)
#
# 検査できないこと(散文の主張と取り違えない)。ここは「渡された内容の整合性検査」であって
# 網羅性・真正性の保証ではない:
#   - **渡されなかった finding は検出できない**。reviewer の実出力と findings を結び付ける
#     ものが無いので、blocker になる finding を 1 件書かなければ通る。
#   - **disposition は統合層の自己申告**。`"見送る"` と書けば blocker が通るが、その値は
#     AskUserQuestion を実際に出したことも人間がそう答えたことも裏付けない。
#   - **tags も自己申告**。[security] の到達点検査はタグが付いている前提で働くので、認証
#     バイパスの指摘を `tags:["quality"]` にすれば検査ごと外れる。
#   - **evidence は形しか見ていない**。裏取りコマンドの語が含まれるかを見るだけで、その
#     コマンドを実際に実行したことも、出力が主張を支持することも確かめていない。
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

# ack 理由は人間の自由文なので、C0 制御文字を空白へ潰してから 1 行として記録する。
# 改行だけでなく C0 全域を潰すのは、ESC を残すとフラグを `cat` した端末表示を書き換え
# られるため。LC_ALL=C で byte 単位に固定する(UTF-8 の継続バイトは C ロケールの cntrl に
# 入らないので日本語は壊れない)。
# **findings 経路の gsub("[[:cntrl:]]") とは射程が違う**: こちらは C0 + DEL だけ、
# あちらは Unicode Cc なので C1(U+0080-U+009F)も潰す。UTF-8 端末は C1 を制御列として
# 解釈しないので実害は薄いが、「守りを揃えた」とは書かない。どちらも U+2028/U+2029 は残す。
oneline() { printf '%s' "${1-}" | LC_ALL=C tr '[:cntrl:]' ' '; }

# findings JSONL を読み切り、検証してから triage 行を生成する。
# 生成側で `triage: ` を前置し、値の改行・CR は空白へ潰す(後続行に偽の head 行を作らせない)。
findings_in="$(cat)"
triage_out=""

# 非空判定にパイプを使わない。`printf … | grep -q` は pipefail 下で fail-open になる:
# grep -q が先頭行の一致で早期終了すると printf が SIGPIPE で 141 を返し、pipefail が
# それを pipeline の値に採るため「非空の findings が空と判定される」。そうなると検証も
# blocker 検査も丸ごと飛んで head 行だけのフラグが立つ。
# 再発するのは **findings がパイプバッファに収まらない**時(書き切れずに printf が
# 残るため)。macOS のバッファは条件により 16KB〜64KB で変わるので固定の閾値で
# 安全域を見積もらない。`[[ =~ ]]` はパイプを介さないのでサイズに依存しない。
# 同じ罠は pane-claude-drive §1 にも明記がある。
if [[ "$findings_in" =~ [^[:space:]] ]]; then
  command -v jq >/dev/null 2>&1 \
    || { echo "jq が無く findings を検証できない。フラグは作らない(fail-closed)。中断" >&2; exit 1; }

  # 1 行 1 レコードを行ごとに検証してから slurp する。まとめて `jq -s` に食わせると
  # 複数行に整形した 1 オブジェクトも通ってしまい、エラーメッセージが実際の受理条件と食い違う。
  # あわせて**重複キー**を弾く: JSON として正当な `{"judgment":"必須",…,"judgment":"見送り可"}` は
  # jq が後勝ちで黙って採用するため、reviewer 由来テキストのエスケープ漏れが判定の上書きに化ける。
  # 重複の検出は**デコード後のキー列**で行う。生文字列の grep で数えると `judgment` の
  # ようなエスケープ済みキーで回避される(grep からは別語に見えるが jq は同じキーとして
  # 後勝ちで採る)。リーフのパスを直接突き合わせるのも不十分で、値の型が違う重複
  # (`{"judgment":{"x":"必須"},"judgment":"推奨"}` / `{"tags":[],"tags":["quality"]}`)は
  # パスが別物になってすり抜ける。**書かれたトップレベル項目の個数**を数えて、デコード後の
  # キー数と突き合わせる:
  #   トップレベル項目 = (パス長 1 のリーフ) + (パス長 2 の close イベント)
  # スカラ値は前者、配列/オブジェクト値は後者に 1 回ずつ現れる。
  #
  # レコード番号は空白行を除いた通し番号で数える(jq -s のインデックスと一致させる。
  # 物理行番号で報告すると、下の slurp 側の「レコード N」と指す先がずれる)。
  findings_lineno=0
  findings_recno=0
  while IFS= read -r fline || [ -n "$fline" ]; do
    findings_lineno=$((findings_lineno + 1))
    [[ "$fline" =~ [^[:space:]] ]] || continue
    findings_recno=$((findings_recno + 1))
    where="レコード ${findings_recno}(findings ${findings_lineno} 行目)"
    jq_err="$(printf '%s' "$fline" | jq -e 'type == "object"' 2>&1 >/dev/null)" \
      || { echo "${where}が 1 行 1 個の JSON オブジェクトでない: ${jq_err}。中断" >&2; exit 1; }
    top_count="$(printf '%s' "$fline" | jq -n --stream -r '
      [inputs] as $e
      | (([$e[] | select(length == 2) | select((.[0] | length) == 1)] | length)
       + ([$e[] | select(length == 1) | select((.[0] | length) == 2)] | length))' 2>&1)" \
      || { echo "${where}の重複キー検査に失敗: ${top_count}。中断" >&2; exit 1; }
    key_count="$(printf '%s' "$fline" | jq -r 'keys | length' 2>&1)" \
      || { echo "${where}の重複キー検査に失敗: ${key_count}。中断" >&2; exit 1; }
    [ "$top_count" = "$key_count" ] \
      || { echo "${where}のトップレベル項目数(${top_count})とキー数(${key_count})が一致しない。同じフィールドが複数回現れる(重複キーは後勝ちで判定を上書きする)か、1 行に 2 レコード以上書かれている。理由文のエスケープ漏れも疑う。中断" >&2; exit 1; }
  done <<EOF_FINDINGS_LINES
$findings_in
EOF_FINDINGS_LINES

  findings_json="$(printf '%s\n' "$findings_in" | jq -s '.' 2>&1)" \
    || { echo "findings を読み込めない: ${findings_json}。中断" >&2; exit 1; }

  # 語彙・必須フィールド・id 重複・gate 条件をまとめて検査する。1 件 1 行のエラーを出し、
  # 非空なら中断する(どれか 1 つでも通らなければフラグを作らない)。
  #
  # 語彙照合に `index` を直接使わない: jq の `index` は**引数が配列だと部分列検索**になり、
  # `judgment: ["要確認","推奨"]` のような配列値が語彙配列の部分列として真になる一方、
  # blocker 配列の部分列ではないので blocker 判定だけが外れる(ゲートのすり抜け)。
  # 文字列であることを先に確かめてから照合する。
  #
  # **id の連番は要求しない**(重複と書式だけ見る)。この findings は「直さなかった finding」の
  # 部分集合なので、直した分の番号が欠けるのが正常。連番を要求すると直すほど弾かれる。
  findings_errs="$(printf '%s' "$findings_json" | jq -r '
    def sev: ["重大","改善","情報"];
    def conf: ["高","中","低","未申告"];
    def judg: ["必須","要確認","推奨","任意","既存","見送り可"];
    def blocking: ["必須","要確認"];
    def dispv: ["見送る","今すぐ修正"];
    def tagv: ["security","quality","perf","test","slop","arch","guide"];

    ( to_entries[]
      | (.key + 1) as $n
      | .value as $f
      | if ($f | type) != "object" then "レコード \($n): JSON オブジェクトでない"
        else
          # triage 行は既知フィールドしか出さないので、未知フィールドは黙って記録から
          # 落ちる。フラグは唯一の durable な記録なので、落ちるより弾く。
          ( ($f | keys) - ["id","severity","tags","confidence","judgment","reason","evidence","disposition"] ) as $unknown
          | ( if ($unknown | length) > 0 then
                "レコード \($n): 未知のフィールド(\($unknown | join(", ")))。記録に出ないので受け付けない"
              else empty end ),
          ( if (($f.id // null) | type) != "string" then "レコード \($n): id が文字列でない"
            elif ($f.id | test("^F-[0-9]{3}\\z")) then empty
            else "レコード \($n): id が F-NNN 形式でない" end ),
          ( if (($f.severity // null) | type) != "string" then "レコード \($n): severity が文字列でない"
            elif (sev | any(. == $f.severity)) then empty
            else "レコード \($n): severity が語彙外(\($f.severity))" end ),
          ( if (($f.confidence // null) | type) != "string" then "レコード \($n): confidence が文字列でない"
            elif (conf | any(. == $f.confidence)) then empty
            else "レコード \($n): confidence が語彙外(\($f.confidence))" end ),
          ( if (($f.judgment // null) | type) != "string" then "レコード \($n): judgment が文字列でない"
            elif (judg | any(. == $f.judgment)) then empty
            else "レコード \($n): judgment が語彙外(\($f.judgment))" end ),
          ( if (($f.tags // null) | type) != "array" then "レコード \($n): tags が配列でない"
            elif ($f.tags | length) == 0 then "レコード \($n): tags が空"
            elif ($f.tags | all(type == "string")) | not then "レコード \($n): tags の要素が文字列でない"
            elif ($f.tags | all(. as $t | tagv | any(. == $t))) | not then
              "レコード \($n): tags に語彙外の値"
            else empty end ),
          ( if (($f.reason // null) | type) != "string" then "レコード \($n): reason が文字列でない"
            elif ($f.reason | test("[^[:space:]]")) then empty
            else "レコード \($n): reason が空(空白のみも空として扱う)" end ),
          ( if ($f | has("evidence")) and (($f.evidence | type) != "string") then
              "レコード \($n): evidence が文字列でない" else empty end ),
          ( if ($f | has("disposition")) then
              ( if ($f.disposition | type) != "string" then "レコード \($n): disposition が文字列でない"
                elif (dispv | any(. == $f.disposition)) then empty
                else "レコード \($n): disposition が語彙外(\($f.disposition))。人間の処置は 見送る / 今すぐ修正 の 2 語で記録する" end )
            else empty end ),
          ( if ($f.judgment == "既存")
                and (((($f.evidence // "") | tostring)
                      | test("git +(log|blame|show|bisect)|commit +[0-9a-f]{7,40}")) | not) then
              "レコード \($n) (\($f.id // "?")): judgment=既存 の evidence に base 側の裏取りコマンドが無い(git log -S / git blame / git show / commit <sha> のいずれかを含めること。裸の 16 進列だけでは通らない)"
            else empty end ),
          ( if (($f.tags // []) | any(. == "security"))
                and ((["必須","要確認","既存"] | any(. == ($f.judgment // ""))) | not) then
              "レコード \($n) (\($f.id // "?")): [security] が Rule R2 の到達点にない(必須 / 要確認 / 裏取り済みの 既存 のいずれかになるはず)。judgment=\($f.judgment // "なし")"
            else empty end ),
          ( if ($f.disposition // "") == "今すぐ修正" then
              "レコード \($n) (\($f.id // "?")): 人間が今すぐ修正と決めた blocker が残っている"
            else empty end ),
          ( if (blocking | any(. == ($f.judgment // ""))) and (($f.disposition // "") != "見送る") then
              "レコード \($n) (\($f.id // "?")): judgment=\($f.judgment) が未決着(人間が見送ると決めた場合のみ disposition=見送る で通す)"
            else empty end )
        end ),
    ( [ .[] | if type == "object" then (.id // "") else "" end ] as $ids
      | if ($ids | length) != ($ids | unique | length) then "id が重複している" else empty end )
  ' 2>&1)" \
    || { echo "findings の検証に失敗(jq): ${findings_errs}。中断" >&2; exit 1; }

  if [ -n "$findings_errs" ]; then
    echo "findings が検証を通らないためフラグを作らない:" >&2
    printf '%s\n' "$findings_errs" >&2
    exit 1
  fi

  # 記録する値は C0 制御文字を全域で潰す。改行だけ潰しても、ESC を含む値をそのまま書くと
  # フラグを `cat` した人間の端末表示が化け、記録の隠蔽に使える(唯一の durable な記録なので
  # 読めない/騙される形にしない)。
  triage_out="$(printf '%s' "$findings_json" | jq -r '
    def oneline: tostring | gsub("[[:cntrl:]]"; " ");
    .[]
    | "triage: \(.id | oneline) [\(.severity)/\(.tags | unique | join(","))] 確信度:\(.confidence) \(.judgment)"
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
# tierN_lastline は呼び出し側が最終行を渡す界面だが、呼び出し側依存を排するため最終行だけを
# 自衛で取り直す(余分な行があっても最終行のみで判定)。ここもパイプを使わない — 判定が
# SIGPIPE で偽に化けると「該当 Tier なし」と読まれ、ack 理由が空のままフラグが立つ。
# 末尾の改行を先に落とす。落とさないと `##*\n` が空文字を返し、空はどの case にも当たらず
# 「該当 Tier なし」と読まれて ack 理由が空のまま通る(Tier 出力を丸ごと貼られた時に踏む)。
tier1_last="${tier1_lastline%$'\n'}"; tier1_last="${tier1_last##*$'\n'}"
tier2_last="${tier2_lastline%$'\n'}"; tier2_last="${tier2_last##*$'\n'}"
case "$tier1_last" in
'TIER1-RESULT: DECREASE'*)
  [ -n "$reason1" ] || { echo "Tier 1 DECREASE の ack 理由が空。中断" >&2; exit 1; } ;;
esac
case "$tier2_last" in
'TIER2-RESULT: RESURRECT'*)
  [ -n "$reason2" ] || { echo "Tier 2 RESURRECT の ack 理由が空。中断" >&2; exit 1; } ;;
esac

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
