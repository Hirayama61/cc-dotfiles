#!/usr/bin/env bats
# self-review skill の移設スクリプトを固定する:
#   - create-review-flag.sh(手順 5 のフラグ作成: ack ゲート / 空フラグ / triage / 既存中断 /
#     RESURRECT 正経路 / 競合時の巻き添え防止 / triage 行の prefix 強制)
#   - run-codex-review.sh(手順 2 の Codex 起動: 未導入 skip / base_ref 空 skip /
#     空応答 skip / 実行失敗 skip / 本文そのまま出力)
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

@test "OK/OK with empty reasons and empty stdin: empty flag created, exit 0" {
  run_create "" "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 0 ]
  local f
  f="$(flag_path)"
  [ -f "$f" ]
  [ ! -s "$f" ]
}

@test "DECREASE with reason1 and two triage lines: records tier1-ack and triage" {
  run_create "$(printf 'triage: F-001 見送り — 誤検知\ntriage: F-002 見送り — 既知')" \
    "TIER1-RESULT: DECREASE cases 3->1" "TIER2-RESULT: OK(none)" "意図的にテスト整理" ""
  [ "$status" -eq 0 ]
  local f
  f="$(flag_path)"
  [ -f "$f" ]
  grep -qF "tier1-ack: 意図的にテスト整理" "$f"
  grep -qF "triage: F-001 見送り — 誤検知" "$f"
  grep -qF "triage: F-002 見送り — 既知" "$f"
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

@test "triage line without prefix gets 'triage: ' prepended (ack spoof blocked)" {
  run_create "tier1-ack: 偽装" "TIER1-RESULT: OK(none)" "TIER2-RESULT: OK(none)" "" ""
  [ "$status" -eq 0 ]
  local f
  f="$(flag_path)"
  [ -f "$f" ]
  # ack 行の偽装は triage: 前置で無害化される。
  grep -qF "triage: tier1-ack: 偽装" "$f"
  # 行頭が tier1-ack: の偽装 ack 行は存在しない。
  ! grep -q '^tier1-ack:' "$f"
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
