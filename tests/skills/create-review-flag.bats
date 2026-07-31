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
  ! grep -q "tier2-ack:" "$f"
}

@test "RESURRECT with reason2: records tier2-ack, exit 0" {
  run_create "" "TIER1-RESULT: OK(none)" "TIER2-RESULT: RESURRECT lines=5" "" "意図的な復活"
  [ "$status" -eq 0 ]
  local f
  f="$(flag_path)"
  [ -f "$f" ]
  grep -qF "tier2-ack: 意図的な復活" "$f"
  # tier1-ack は理由が無いので書かれない。
  ! grep -q "tier1-ack:" "$f"
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

@test "empty reason blocks the flag" {
  run_create '{"id":"F-001","severity":"改善","tags":["quality"],"confidence":"中","judgment":"推奨","reason":""}' \
    "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 1 ]
  [ ! -e "$(flag_path)" ]
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
  ! LC_ALL=C grep -q '[^[:print:][:space:]]' "$f"
  grep -qF 'triage: F-001 [改善/quality] 確信度:中 推奨 — 前 [2J後' "$f"
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
  grep -qF '壊れ方' "$SHIM_ARGV_OUT"
  grep -qF '全件' "$SHIM_ARGV_OUT"
}
