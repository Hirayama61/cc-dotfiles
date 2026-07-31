#!/usr/bin/env bats
# self-review skill の移設スクリプトを固定する:
#   - create-review-flag.sh(手順 5 のフラグ作成: ack ゲート / 空フラグ / 既存中断 /
#     RESURRECT 正経路 / 競合時の巻き添え防止 / findings JSONL の検証と triage 行の生成 —
#     語彙・型・重複キー・id 重複・blocker 残留・[security] の到達点・裏取り根拠・
#     制御文字の除去・jq 不在の fail-closed)
#   - run-codex-review.sh(手順 2 の Codex 起動: 未導入 skip / base_ref 空 skip /
#     空応答 skip / 実行失敗 skip / 本文そのまま出力 / 出力契約が指示文に入っていること)
#
# common.bash の install_hooks で一時 HOME に hooks/lib(executable_ を剥がす)を複製し、
# HOME を差し替える(create-review-flag.sh は $HOME/.claude/hooks/lib の
# resolve-repo-key.sh / flag-paths.sh を実行時参照する)。XDG_STATE_HOME は unset にして
# flag dir を一時 HOME 配下(=$HOME/.local/state/claude-sessions)へ倒す。判定対象の repo は
# 一時 git repo を別途用意し、branch work を切る。

load ../helpers/common

setup() {
  install_hooks
  unset XDG_STATE_HOME

  local scripts="$REPO_ROOT/home/dot_claude/skills/self-review/scripts"
  CREATE="$scripts/executable_create-review-flag.sh"
  CODEX="$scripts/executable_run-codex-review.sh"

  # 判定対象の一時 git repo(HOME とは別ツリー)に branch work を用意する。
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" checkout -q -b work
  git -C "$REPO" -c user.email=t@example.com -c user.name=t \
    commit -q --allow-empty -m init
}

# create-review-flag.sh を REPO を cwd に、stdin を与えて実行する。
#   run_create <stdin> <tier1_lastline> <tier2_lastline> <reason1> <reason2>
run_create() {
  run bash -c '
    cd "$1" || exit 99
    printf "%s" "$2" | bash "$3" "$4" "$5" "$6" "$7"
  ' _ "$REPO" "$1" "$CREATE" "$2" "$3" "$4" "$5"
}

# 生成される review-passed フラグの絶対パス(lib 経由でキーを引く)。
flag_path() {
  local repo
  repo="$("$HOME/.claude/hooks/lib/resolve-repo-key.sh" "$REPO")"
  "$HOME/.claude/hooks/lib/flag-paths.sh" review-passed "$repo" work
}

# 判定対象 repo の現 HEAD(フラグ 1 行目に書かれる期待値)。
head_sha() {
  git -C "$REPO" rev-parse HEAD
}

# findings JSONL の 1 レコードを組み立てる(stdin 用)。
#   finding <id> <severity> <tag> <confidence> <judgment> <reason> [evidence] [disposition]
finding() {
  printf '{"id":"%s","severity":"%s","tags":["%s"],"confidence":"%s","judgment":"%s","reason":"%s"' \
    "$1" "$2" "$3" "$4" "$5" "$6"
  [ -n "${7-}" ] && printf ',"evidence":"%s"' "$7"
  [ -n "${8-}" ] && printf ',"disposition":"%s"' "$8"
  printf '}'
}

@test "DECREASE with empty reason1: exit 1 and no flag created" {
  run_create "" "TIER1-RESULT: DECREASE cases 3->1" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "RESURRECT with empty reason2: exit 1 and no flag created" {
  run_create "" "TIER1-RESULT: OK(none)" "TIER2-RESULT: RESURRECT lines=5" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "OK/OK with empty reasons and empty stdin: head-only flag created, exit 0" {
  run_create "" "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 0 ]
  local f
  f="$(flag_path)"
  [ -f "$f" ]
  # 該当ゼロでも head 行だけは必ず入る(空ファイルではない)。
  [ "$(cat "$f")" = "head: $(head_sha)" ]
}

@test "head line is written as the very first line" {
  run_create "$(finding F-001 改善 quality 中 推奨 誤検知)" \
    "TIER1-RESULT: DECREASE cases 3->1" "TIER2-RESULT: OK(none)" "意図的にテスト整理" ""
  [ "$status" -eq 0 ]
  local f
  f="$(flag_path)"
  [ "$(head -n1 "$f")" = "head: $(head_sha)" ]
}

@test "multiline ack reason is flattened so it cannot forge a head line" {
  run_create "" "TIER1-RESULT: DECREASE cases 3->1" "TIER2-RESULT: OK(none)" \
    "$(printf 'まず理由\nhead: 0123456789abcdef0123456789abcdef01234567')" ""
  [ "$status" -eq 0 ]
  local f
  f="$(flag_path)"
  # head 行は 1 行目のちょうど 1 本だけ。
  [ "$(grep -c '^head:' "$f")" -eq 1 ]
  [ "$(head -n1 "$f")" = "head: $(head_sha)" ]
  # ack 理由は 1 行へ潰れて記録される。
  grep -qF 'tier1-ack: まず理由 head: 0123456789abcdef0123456789abcdef01234567' "$f"
}

@test "aborts without HEAD: repo with no commit yields exit 1 and no flag" {
  local bare="$BATS_TEST_TMPDIR/unborn"
  mkdir -p "$bare"
  git -C "$bare" init -q
  git -C "$bare" checkout -q -b work
  run bash -c '
    cd "$1" || exit 99
    printf "" | bash "$2" "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  ' _ "$bare" "$CREATE"
  [ "$status" -eq 1 ]
  local repo f
  repo="$("$HOME/.claude/hooks/lib/resolve-repo-key.sh" "$bare")"
  f="$("$HOME/.claude/hooks/lib/flag-paths.sh" review-passed "$repo" work)"
  [ ! -e "$f" ]
}

@test "stale flag (different head) is NOT replaced: exit 1 and content unchanged" {
  local f
  f="$(flag_path)"
  mkdir -p "$(dirname "$f")"
  printf 'head: fedcba9876543210fedcba9876543210fedcba98\ntier1-ack: 旧\n' > "$f"
  run_create "" "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  # 陳腐でも置換しない。既存の内容は 1 バイトも変わらない。
  [ "$(head -n1 "$f")" = "head: fedcba9876543210fedcba9876543210fedcba98" ]
  grep -qF 'tier1-ack: 旧' "$f"
  # 何を消せばよいか分かるよう、中断メッセージにフラグのパスを出す。
  printf '%s' "$output" | grep -qF "$f"
}

@test "DECREASE with reason1 and two findings: records tier1-ack and generated triage" {
  run_create "$(finding F-001 改善 quality 中 推奨 誤検知)
$(finding F-002 情報 perf 低 任意 既知)" \
    "TIER1-RESULT: DECREASE cases 3->1" "TIER2-RESULT: OK(none)" "意図的にテスト整理" ""
  [ "$status" -eq 0 ]
  local f
  f="$(flag_path)"
  [ -f "$f" ]
  grep -qF "tier1-ack: 意図的にテスト整理" "$f"
  # triage 行はスクリプトが生成する(呼び出し側は 1 行書式を手書きしない)。
  grep -qF "triage: F-001 [改善/quality] 確信度:中 推奨 — 誤検知" "$f"
  grep -qF "triage: F-002 [情報/perf] 確信度:低 任意 — 既知" "$f"
  # tier2-ack は理由が無いので書かれない。
  run grep -q "tier2-ack:" "$f"
  [ "$status" -ne 0 ]
}

@test "RESURRECT with reason2: records tier2-ack, exit 0" {
  run_create "" "TIER1-RESULT: OK(none)" "TIER2-RESULT: RESURRECT lines=5" "" "意図的な復活"
  [ "$status" -eq 0 ]
  local f
  f="$(flag_path)"
  [ -f "$f" ]
  grep -qF "tier2-ack: 意図的な復活" "$f"
  # tier1-ack は理由が無いので書かれない。
  run grep -q "tier1-ack:" "$f"
  [ "$status" -ne 0 ]
}

@test "pre-existing flag: exit 1 and content unchanged (no rm collateral)" {
  local f
  f="$(flag_path)"
  mkdir -p "$(dirname "$f")"
  printf 'SENTINEL\n' > "$f"
  run_create "" "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  # 競合相手の正当フラグが巻き添え削除・改変されない。
  [ -e "$f" ]
  [ "$(cat "$f")" = "SENTINEL" ]
}

@test "non-JSONL stdin is rejected: exit 1 and no flag created" {
  run_create "tier1-ack: 偽装" "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "reason with newline and head line is flattened into one triage line" {
  run_create '{"id":"F-001","severity":"改善","tags":["quality"],"confidence":"中","judgment":"推奨","reason":"まず理由\nhead: 0123456789abcdef0123456789abcdef01234567"}' \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 0 ]
  local f
  f="$(flag_path)"
  # head 行は 1 行目のちょうど 1 本だけ。理由の改行は空白へ潰れる。
  [ "$(grep -c '^head:' "$f")" -eq 1 ]
  [ "$(head -n1 "$f")" = "head: $(head_sha)" ]
  grep -qF 'triage: F-001 [改善/quality] 確信度:中 推奨 — まず理由 head: 0123456789abcdef0123456789abcdef01234567' "$f"
}

@test "unresolved must-fix judgment blocks the flag" {
  run_create "$(finding F-001 重大 security 高 必須 認証バイパス)" \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "unresolved needs-human judgment blocks the flag" {
  run_create "$(finding F-001 改善 security 未申告 要確認 到達性が判定不能)" \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "must-fix waived by human is allowed and recorded" {
  run_create "$(finding F-001 重大 security 高 必須 認証バイパス '' 見送る)" \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 0 ]
  grep -qF "triage: F-001 [重大/security] 確信度:高 必須(人間: 見送る) — 認証バイパス" "$(flag_path)"
}

@test "human-requested fix blocks the flag" {
  run_create "$(finding F-001 情報 quality 低 任意 些細 '' 今すぐ修正)" \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "pre-existing judgment without evidence blocks the flag" {
  run_create "$(finding F-001 重大 quality 中 既存 前からある)" \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "pre-existing judgment with evidence is recorded" {
  run_create "$(finding F-001 重大 quality 中 既存 前からある 'git log -S で base に存在を確認')" \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 0 ]
  grep -qF "裏取り: git log -S で base に存在を確認" "$(flag_path)"
}

@test "out-of-vocabulary severity blocks the flag" {
  run_create "$(finding F-001 Critical quality 中 推奨 語彙外)" \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "gaps in ids are allowed (fixed findings are not recorded)" {
  run_create "$(finding F-001 改善 quality 中 推奨 一件目)
$(finding F-003 改善 quality 中 推奨 二件目)" \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 0 ]
  grep -qF "triage: F-003 " "$(flag_path)"
}

@test "duplicate ids block the flag" {
  run_create "$(finding F-001 改善 quality 中 推奨 一件目)
$(finding F-001 改善 quality 中 推奨 二件目)" \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "array-valued judgment blocks the flag (jq index subsequence bypass)" {
  run_create '{"id":"F-001","severity":"重大","tags":["security"],"confidence":"高","judgment":["要確認","推奨"],"reason":"認証バイパスの疑い"}' \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "array-valued severity blocks the flag" {
  run_create '{"id":"F-001","severity":["重大"],"tags":["quality"],"confidence":"高","judgment":"推奨","reason":"r"}' \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "duplicate field in one record blocks the flag (last-wins override)" {
  run_create '{"id":"F-001","severity":"重大","tags":["quality"],"confidence":"高","judgment":"必須","reason":"認証バイパス","judgment":"見送り可"}' \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "escaped duplicate key blocks the flag (raw grep would miss it)" {
  # キーを JSON エスケープすると生文字列の突き合わせからは別語に見えるが、
  # jq は同じキーとして後勝ちで採る。検出はデコード後のキー列で行う。
  local esc payload
  esc="$(printf '\\u006d')"
  payload="{\"id\":\"F-001\",\"severity\":\"重大\",\"tags\":[\"quality\"],\"confidence\":\"高\",\"judgment\":\"必須\",\"reason\":\"r\",\"judg${esc}ent\":\"見送り可\"}"
  run_create "$payload" "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "duplicate key with a nested value blocks the flag (leaf paths differ)" {
  # リーフのパスだけを突き合わせると ["judgment","x"] と ["judgment"] が別物になり抜ける。
  # トップレベル項目数とキー数の比較なら型が違っても捕まる。
  run_create '{"id":"F-001","severity":"重大","tags":["security"],"confidence":"高","judgment":{"x":"必須"},"judgment":"推奨","reason":"r"}' \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "duplicate key with an empty-array value blocks the flag" {
  run_create '{"id":"F-001","severity":"改善","tags":[],"tags":["quality"],"confidence":"中","judgment":"推奨","reason":"r"}' \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "two records on one line block the flag" {
  run_create "$(printf '%s %s' \
    '{"id":"F-001","severity":"改善","tags":["quality"],"confidence":"中","judgment":"推奨","reason":"r"}' \
    '{"id":"F-002","severity":"改善","tags":["quality"],"confidence":"中","judgment":"推奨","reason":"r"}')" \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "nested objects and arrays alone do not trip the duplicate check" {
  run_create "$(finding F-001 改善 quality 中 推奨 r)" \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 0 ]
  grep -qF "triage: F-001 [改善/quality]" "$(flag_path)"
}

@test "out-of-vocabulary disposition blocks the flag" {
  run_create "$(finding F-001 改善 quality 中 推奨 些細 '' '今すぐ修正(F-002 と併せて)')" \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "security tag with non-blocking judgment blocks the flag" {
  run_create "$(finding F-001 重大 security 高 見送り可 誤検知だと思う)" \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "security tag with verified pre-existing judgment is allowed" {
  run_create "$(finding F-001 重大 security 高 既存 前からある 'git blame で base 側に存在を確認')" \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 0 ]
  grep -qF "triage: F-001 [重大/security]" "$(flag_path)"
}

@test "token-only evidence blocks the flag" {
  run_create "$(finding F-001 改善 quality 中 既存 前からある -)" \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "bare hex evidence blocks the flag (no verification command)" {
  # 7 文字以上の 16 進列だけを見ると英単語 defaced も 1234567 も通る。
  # 裏取りは「コマンドを打った痕跡」を要求する。
  run_create "$(finding F-001 改善 quality 中 既存 前からある 'defaced')" \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "evidence naming a commit sha with a verb is allowed" {
  run_create "$(finding F-001 改善 quality 中 既存 前からある 'commit 0e21db5 で既に存在')" \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 0 ]
  grep -qF '裏取り: commit 0e21db5 で既に存在' "$(flag_path)"
}

@test "empty reason blocks the flag" {
  run_create '{"id":"F-001","severity":"改善","tags":["quality"],"confidence":"中","judgment":"推奨","reason":""}' \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "whitespace-only reason blocks the flag" {
  run_create '{"id":"F-001","severity":"改善","tags":["quality"],"confidence":"中","judgment":"推奨","reason":"   "}' \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "duplicate tags are collapsed in the triage line" {
  run_create '{"id":"F-001","severity":"改善","tags":["quality","quality"],"confidence":"中","judgment":"推奨","reason":"r"}' \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 0 ]
  grep -qF 'triage: F-001 [改善/quality] 確信度:中 推奨 — r' "$(flag_path)"
}

@test "tags as non-array blocks the flag" {
  run_create '{"id":"F-001","severity":"改善","tags":"quality","confidence":"中","judgment":"推奨","reason":"r"}' \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "empty tags array blocks the flag" {
  run_create '{"id":"F-001","severity":"改善","tags":[],"confidence":"中","judgment":"推奨","reason":"r"}' \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "out-of-vocabulary tag blocks the flag" {
  run_create '{"id":"F-001","severity":"改善","tags":["obsidian"],"confidence":"中","judgment":"推奨","reason":"r"}' \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "control characters in reason are stripped from the triage line" {
  run_create '{"id":"F-001","severity":"改善","tags":["quality"],"confidence":"中","judgment":"推奨","reason":"前\u001b[2J後"}' \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 0 ]
  local f
  f="$(flag_path)"
  # ESC はそのまま書かれない(端末表示の細工・記録の隠蔽を防ぐ)。
  run env LC_ALL=C grep -q '[[:cntrl:]]' "$f"
  [ "$status" -ne 0 ]
  grep -qF 'triage: F-001 [改善/quality] 確信度:中 推奨 — 前 [2J後' "$f"
}

@test "control characters in an ack reason are stripped" {
  # ack 理由は argv 経由で findings の jq を通らない。改行だけ潰すと ESC が残り、
  # フラグを cat した端末表示を書き換えられる(findings 経路と守りを揃える)。
  run_create "" "TIER1-RESULT: DECREASE(1)" "TIER2-RESULT: OK(none)" \
    "ack$(printf '\033')[2K$(printf '\033')[Aほんとは未確認" ""
  [ "$status" -eq 0 ]
  local f
  f="$(flag_path)"
  run env LC_ALL=C grep -q '[[:cntrl:]]' "$f"
  [ "$status" -ne 0 ]
  grep -qF 'tier1-ack: ack [2K [Aほんとは未確認' "$f"
}

@test "a large findings payload is still validated (no SIGPIPE fail-open)" {
  # 非空判定を `printf … | grep -q` で書くと、pipefail 下で grep -q の早期終了が printf に
  # SIGPIPE を返し pipeline が 141 になる。findings は「空」と読まれて検証も blocker 検査も
  # 飛び、head 行だけのフラグが立つ。実測: この payload を修正前のスクリプトへ食わせると
  # exit 0 でフラグが作られる(未決着の `必須` + `[security]` を先頭に置いてある)。
  # **パイプバッファを確実に超えること**が要件。macOS のパイプバッファは条件により
  # 16KB〜64KB で変わるので固定の閾値を信じない。バイトで測る(`${#var}` は UTF-8 では
  # 文字数を返すので、理由文の日本語比率が変わるだけで意図した領域から外れる)。
  local payload
  payload="$(finding F-001 重大 security 高 必須 認証バイパス)"
  local i
  for i in $(seq 2 900); do
    payload="${payload}"$'\n'"$(finding "F-$(printf '%03d' "$i")" 情報 quality 低 見送り可 些細な指摘であり対応不要と判断した)"
  done
  [ "$(printf '%s' "$payload" | wc -c)" -gt 100000 ]
  run_create "$payload" "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "a large findings payload with no blocker still creates the flag" {
  # 上の裏返し。パイプバッファ超えでも正常系が壊れていないこと(検証が走ったうえで通る)。
  local payload i
  payload="$(finding F-001 情報 quality 低 見送り可 些細な指摘であり対応不要と判断した)"
  for i in $(seq 2 900); do
    payload="${payload}"$'\n'"$(finding "F-$(printf '%03d' "$i")" 情報 quality 低 見送り可 些細な指摘であり対応不要と判断した)"
  done
  [ "$(printf '%s' "$payload" | wc -c)" -gt 100000 ]
  run_create "$payload" "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 0 ]
  grep -qF 'triage: F-400 ' "$(flag_path)"
}

@test "DECREASE with a multi-line tier argument still demands an ack reason" {
  # 最終行の取り出しにパイプを使うと、SIGPIPE で判定が偽に化けて
  # 「該当 Tier なし」と読まれ、ack 理由が空のままフラグが立つ(fail-open)。
  run_create "" "TIER1-RESULT: SKIP(前段)"$'\n'"TIER1-RESULT: DECREASE(2)" \
    "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "id with a trailing newline blocks the flag" {
  # jq(Oniguruma)の `$` は末尾改行の直前にも当たるので `^F-[0-9]{3}$` は "F-001\n" を通す。
  # 通ると triage 行が 2 物理行に割れ、後半が `triage: ` 接頭辞を持たない継続行になる。
  run_create '{"id":"F-001\n","severity":"改善","tags":["quality"],"confidence":"中","judgment":"推奨","reason":"r"}' \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "every triage line starts with the triage prefix" {
  # 記録は 1 件 1 行が前提(件数を数える読み手が居る)。どの値が来ても行が割れないことを固定する。
  run_create "$(finding F-001 改善 quality 中 推奨 r)" \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 0 ]
  local f
  f="$(flag_path)"
  # 1 行目の head 行を除く全行が triage 行であること。
  [ "$(tail -n +2 "$f" | wc -l | tr -d ' ')" = "$(grep -c '^triage: ' "$f" | tr -d ' ')" ]
}

@test "an unknown field blocks the flag (it would vanish from the record)" {
  run_create '{"id":"F-001","severity":"改善","tags":["quality"],"confidence":"中","judgment":"推奨","reason":"r","note":"重要な補足"}' \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "DECREASE with a trailing newline still demands an ack reason" {
  # 末尾改行を落とさずに最終行を取ると空文字になり、空はどの case にも当たらないので
  # 「該当 Tier なし」と読まれて ack 理由が空のまま通る。Tier 出力を丸ごと貼ると踏む。
  run_create "" "TIER1-RESULT: DECREASE(2)"$'\n' "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "DECREASE with multiple trailing newlines still demands an ack reason" {
  # `%$'\n'` は 1 個しか落とさないため、改行が 2 個以上あると最終行の取り出しが空文字に
  # なり、空はどの case にも当たらないので「該当 Tier なし」と読まれて ack 理由が空のまま
  # 通ってしまう(fail-open)回帰を防ぐ。
  run_create "" "TIER1-RESULT: DECREASE(2)"$'\n\n' "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "missing jq blocks the flag (fail-closed)" {
  # jq 不在 PATH の組み立ては common.bash の helper が正典(ホワイトリストを二重化しない)。
  local stub
  stub="$(make_no_jq_path)"
  [ ! -e "$stub/jq" ]
  run bash -c '
    cd "$1" || exit 99
    PATH="$2"
    export PATH
    printf "%s" "$3" | bash "$4" "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  ' _ "$REPO" "$stub" "$(finding F-001 改善 quality 中 推奨 誤検知)" "$CREATE"
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
}

@test "run-codex-review.sh: codex absent on PATH yields skip and exit 0" {
  local bash_bin empty
  bash_bin="$(command -v bash)"
  empty="$BATS_TEST_TMPDIR/emptybin"
  mkdir -p "$empty"
  run env PATH="$empty" "$bash_bin" "$CODEX" main
  [ "$status" -eq 0 ]
  [ "$output" = "Codex: skip(未導入)" ]
}

# fake codex を PATH 先頭の shim dir に置いて run-codex-review.sh を REPO 内で実行する。
#   run_codex <shim_dir> <base_ref>
run_codex() {
  run env PATH="$1:$PATH" bash -c '
    cd "$1" || exit 99
    bash "$2" "$3"
  ' _ "$REPO" "$CODEX" "$2"
}

@test "run-codex-review.sh: empty base_ref yields skip and exit 0" {
  run bash "$CODEX" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex: skip("* ]]
}

@test "run-codex-review.sh: codex exit 0 empty output yields empty-response skip" {
  local shim="$BATS_TEST_TMPDIR/codex-empty"
  mkdir -p "$shim"
  cat > "$shim/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
exit 0
EOF
  chmod +x "$shim/codex"
  run_codex "$shim" HEAD
  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex: skip(空応答"* ]]
}

@test "run-codex-review.sh: codex exit 1 partial output yields run-failure skip" {
  local shim="$BATS_TEST_TMPDIR/codex-fail"
  mkdir -p "$shim"
  cat > "$shim/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf 'partial output\n'
exit 1
EOF
  chmod +x "$shim/codex"
  run_codex "$shim" HEAD
  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex: skip(実行失敗"* ]]
}

@test "run-codex-review.sh: codex exit 0 body output is printed verbatim" {
  local shim="$BATS_TEST_TMPDIR/codex-body"
  mkdir -p "$shim"
  cat > "$shim/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf 'CODEX-BODY-MARKER\n'
exit 0
EOF
  chmod +x "$shim/codex"
  run_codex "$shim" HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "CODEX-BODY-MARKER" ]
}

@test "run-codex-review.sh: the output contract is present in the prompt argument" {
  # Codex は Agent ではないので skill が起動時に契約を足せない。指示文が唯一の注入点なので、
  # 契約が指示文から消えたらここで落ちるようにする(消えても他のテストは全部緑になる)。
  local shim="$BATS_TEST_TMPDIR/codex-argv"
  mkdir -p "$shim"
  cat > "$shim/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf '%s' "$*" > "$SHIM_ARGV_OUT"
printf 'ok\n'
exit 0
EOF
  chmod +x "$shim/codex"
  SHIM_ARGV_OUT="$BATS_TEST_TMPDIR/codex-argv.txt"
  export SHIM_ARGV_OUT
  run_codex "$shim" HEAD
  [ "$status" -eq 0 ]
  [ -f "$SHIM_ARGV_OUT" ]
  # 契約は 4 条項。1 つでも指示文から落ちたらここで気づけるよう全部を固定する。
  grep -qF '壊れ方' "$SHIM_ARGV_OUT"
  grep -qF '命名からの推測だけで断定するな' "$SHIM_ARGV_OUT"
  grep -qF '数行に収めよ' "$SHIM_ARGV_OUT"
  grep -qF '全件' "$SHIM_ARGV_OUT"
}
