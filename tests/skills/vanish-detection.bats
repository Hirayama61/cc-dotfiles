#!/usr/bin/env bats
# self-review skill の消失検知 3 本の**最終行契約**を固定する:
#   - test-vanish-check.sh    (Tier 1: TIER1-RESULT: DECREASE / OK / SKIP)
#   - code-resurrect-check.sh (Tier 2: TIER2-RESULT: RESURRECT / OK / SKIP)
#   - scope-deviation-check.sh(Tier 3: TIER3-RESULT: DEVIATION / OK / SKIP)
#
# 呼び出し側(self-review skill)が機械解釈するのは最終行だけなので、検証も最終行に
# 寄せる(詳細行はファイル内容由来のテキストを含むため契約に含めない)。特に
# **判定不能が偽 OK に化けないこと**(lib 不達/破損/旧版・ERE 破損・計数不能パス・
# スコープ宣言なし → いずれも SKIP)を各 Tier で固定する。exit code は常に 0。
#
# common.bash の install_hooks で一時 HOME に hooks/lib(executable_ を剥がす)を複製し
# HOME を差し替える(3 本とも $HOME/.claude/hooks/lib を実行時参照する)。XDG_STATE_HOME は
# unset にして Tier 3 のスコープフラグを一時 HOME 配下(=$HOME/.local/state/claude-sessions)へ
# 倒す。判定対象の repo は BATS_TEST_TMPDIR 配下の一時 git repo。

# `run --separate-stderr` は bats 1.5.0 以降。宣言しないと BW02 警告が出る。
bats_require_minimum_version 1.5.0

load ../helpers/common

setup() {
  # 継承環境の GIT_* は repo の位置(`git -C` では上書きされない)・diff の実装
  # (GIT_EXTERNAL_DIFF は patch を出さないので追加行 0 件に化ける)・config 注入
  # (GIT_CONFIG_COUNT は GIT_CONFIG_GLOBAL=/dev/null を迂回して core.hooksPath を張れる)
  # のいずれにも効く。列挙は取りこぼすので、一掃してから必要な 2 本だけ張り直す。
  for v in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  install_hooks
  unset XDG_STATE_HOME

  # resolve_base_ref の手順 1 は gh で PR base を引く。実 gh の認証状態やネットワークで
  # 結果が揺れないよう、常に失敗する shim を PATH 先頭に置き merge-base フォールバック
  # 経路(手順 2)に固定する。
  local shim="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$shim"
  printf '#!/bin/sh\nexit 1\n' >"$shim/gh"
  chmod +x "$shim/gh"
  export PATH="$shim:$PATH"

  local scripts="$REPO_ROOT/home/dot_claude/skills/self-review/scripts"
  TIER1="$scripts/executable_test-vanish-check.sh"
  TIER2="$scripts/executable_code-resurrect-check.sh"
  TIER3="$scripts/executable_scope-deviation-check.sh"

  LIB="$HOME/.claude/hooks/lib"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" checkout -q -b main
}

# 機械解釈の対象になる最終行だけを取り出す。呼び出し側はコマンド置換で stdout だけを取るため、
# `run --separate-stderr` と対で使う($output に stderr が混ざると契約が別ビューになる)。
last_line() {
  printf '%s\n' "$output" | tail -n 1
}

# 最終行の前方一致。bash 3.2 は `set -e` 下で非末尾の `[[ ]]` の失敗を伝播しない。
# 引数を 1 個の非空に固定するのは、空/未設定だと `""*` が全一致して常に成功するため。
assert_last_line_prefix() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || { printf 'usage: assert_last_line_prefix <non-empty-prefix>\n' >&2; return 2; }
  local actual
  actual="$(last_line)"
  case "$actual" in
  "$1"*) return 0 ;;
  esac
  printf 'expected prefix: %s\n' "$1" >&2
  printf 'actual         : %s\n' "$actual" >&2
  return 1
}

# write_file <REPO 相対パス>  … 内容は stdin。
write_file() {
  mkdir -p "$(dirname "$REPO/$1")"
  cat >"$REPO/$1"
}

# commit_all <message>
commit_all() {
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@example.com -c user.name=t commit -q -m "$1"
}

# git 管理外の一時ディレクトリ(repo 外 SKIP の検証用)。
plain_dir() {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  printf '%s' "$BATS_TEST_TMPDIR/plain"
}

# 2 件のテストケースを持つテストファイルで main を作り、work ブランチへ移る。
seed_tests_on_main() {
  write_file tests/foo.test.js <<'EOF'
describe("suite", () => {
  it("alpha works", () => { expect(1).toBe(1); });
  it("beta works", () => { expect(2).toBe(2); });
});
EOF
  commit_all init
  git -C "$REPO" checkout -q -b work
}

# ── Tier 1: test-vanish-check.sh ────────────────────────────────────────────

@test "tier1: removed test case yields DECREASE" {
  seed_tests_on_main
  write_file tests/foo.test.js <<'EOF'
describe("suite", () => {
  it("alpha works", () => { expect(1).toBe(1); });
});
EOF
  commit_all drop
  run --separate-stderr bash "$TIER1" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER1-RESULT: DECREASE files=1 cases=-1 asserts=-2" ]
}

@test "tier1: renamed title with unchanged counts still yields DECREASE" {
  seed_tests_on_main
  # 1 件削除 + 1 件追加でカウントは相殺する。title 集合差で拾えないと偽 OK になる。
  write_file tests/foo.test.js <<'EOF'
describe("suite", () => {
  it("alpha works", () => { expect(1).toBe(1); });
  it("gamma works", () => { expect(2).toBe(2); });
});
EOF
  commit_all retitle
  run --separate-stderr bash "$TIER1" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER1-RESULT: DECREASE files=1 cases=0 asserts=0" ]
}

@test "tier1: added test case yields OK" {
  seed_tests_on_main
  write_file tests/foo.test.js <<'EOF'
describe("suite", () => {
  it("alpha works", () => { expect(1).toBe(1); });
  it("beta works", () => { expect(2).toBe(2); });
  it("delta works", () => { expect(3).toBe(3); });
});
EOF
  commit_all add
  run --separate-stderr bash "$TIER1" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER1-RESULT: OK(テスト観点の減少なし)" ]
}

@test "tier1: rename inside test naming is not a vanish (OK)" {
  seed_tests_on_main
  git -C "$REPO" mv tests/foo.test.js tests/bar.test.js
  commit_all rename
  run --separate-stderr bash "$TIER1" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER1-RESULT: OK(テスト観点の減少なし)" ]
}

@test "tier1: rename out of test naming yields DECREASE" {
  seed_tests_on_main
  mkdir -p "$REPO/src"
  git -C "$REPO" mv tests/foo.test.js src/foo.js
  commit_all rename-out
  run --separate-stderr bash "$TIER1" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  # 内容は残っていてもランナーの discovery から消えるので新側 0 カウント扱い。
  [ "$(last_line)" = "TIER1-RESULT: DECREASE files=1 cases=-3 asserts=-4" ]
}

@test "tier1: non-test file change is ignored (OK)" {
  # 非テスト命名のファイルを work 側で減らす。ファイル判定の ERE が効いていなければ
  # DECREASE になるので、OK であることがフィルタ自体の検証になる。
  write_file src/app.js <<'EOF'
it("alpha works", () => { expect(1).toBe(1); });
it("beta works", () => { expect(2).toBe(2); });
EOF
  commit_all init
  git -C "$REPO" checkout -q -b work
  write_file src/app.js <<'EOF'
it("alpha works", () => { expect(1).toBe(1); });
EOF
  commit_all shrink
  run --separate-stderr bash "$TIER1" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER1-RESULT: OK(テスト観点の減少なし)" ]
}

@test "tier1: uncountable quoted path yields SKIP not OK" {
  # C-quote されるパス(引用符入り)は内容を読めない。無音で 0 件に倒すとテスト削除の
  # 偽 OK になるため計数不能 = SKIP。
  write_file 'tests/we"ird.test.js' <<'EOF'
it("alpha works", () => { expect(1).toBe(1); });
it("beta works", () => { expect(2).toBe(2); });
EOF
  commit_all init
  git -C "$REPO" checkout -q -b work
  write_file 'tests/we"ird.test.js' <<'EOF'
it("alpha works", () => { expect(1).toBe(1); });
EOF
  commit_all shrink
  run --separate-stderr bash "$TIER1" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  assert_last_line_prefix "TIER1-RESULT: SKIP(計数不能ファイル 1 件"
}

@test "tier1: missing lib yields SKIP" {
  seed_tests_on_main
  rm -f "$LIB/test-patterns.sh"
  run --separate-stderr bash "$TIER1" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER1-RESULT: SKIP(lib 不達: test-patterns.sh)" ]
}

@test "tier1: corrupt lib yields SKIP" {
  seed_tests_on_main
  printf 'if [ ; then\n' >"$LIB/test-patterns.sh"
  run --separate-stderr bash "$TIER1" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER1-RESULT: SKIP(lib 破損: test-patterns.sh)" ]
}

@test "tier1: stale lib without count helpers yields SKIP" {
  # apply skew で関数が無い旧 lib を読むと両側 0 カウントの偽 OK になる。存在検査で SKIP。
  seed_tests_on_main
  printf '#!/usr/bin/env bash\n:\n' >"$LIB/test-patterns.sh"
  run --separate-stderr bash "$TIER1" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  assert_last_line_prefix "TIER1-RESULT: SKIP(lib 旧版: test_file_ere 未定義"
}

@test "tier1: broken ERE yields SKIP not OK" {
  # ERE が不正だと grep が rc>=2 で全件 0 になり偽 OK に化ける。事前検証で SKIP。
  seed_tests_on_main
  cat >"$LIB/test-patterns.sh" <<'EOF'
#!/usr/bin/env bash
test_file_ere() { printf '%s' '(\.(test|spec)\.[a-zA-Z]+|__tests__/|/tests?/)'; }
test_case_ere() { printf '%s' '('; }
test_assert_ere() { printf '%s' 'x'; }
EOF
  run --separate-stderr bash "$TIER1" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER1-RESULT: SKIP(ERE 検証失敗(lib 破損疑い))" ]
}

@test "tier1: no protected ancestor yields SKIP" {
  seed_tests_on_main
  # 保護ブランチ(main/master/develop/epic/*)の実 ref を消すと base が解決できない。
  git -C "$REPO" branch -D main
  run --separate-stderr bash "$TIER1" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER1-RESULT: SKIP(base 解決不能(保護祖先なし))" ]
}

@test "tier1: outside a git repo yields SKIP" {
  run --separate-stderr bash "$TIER1" "$(plain_dir)"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  assert_last_line_prefix "TIER1-RESULT: SKIP(git repo 外: "
}

# ── Tier 2: code-resurrect-check.sh ─────────────────────────────────────────

# main に「後で削除される行」を仕込み、削除済みの状態から work を切る。
#   c1: 行あり → c2: base が削除 → work 分岐
seed_deleted_line_on_main() {
  write_file src/app.js <<'EOF'
function head() { return 1; }
const importantHelper = computeValue(alpha, beta);
function tail() { return 2; }
EOF
  commit_all c1
  write_file src/app.js <<'EOF'
function head() { return 1; }
function tail() { return 2; }
EOF
  commit_all c2
  git -C "$REPO" checkout -q -b work
}

# work 側で削除済みの行を書き戻す(復活)。
readd_deleted_line() {
  write_file src/app.js <<'EOF'
function head() { return 1; }
const importantHelper = computeValue(alpha, beta);
function tail() { return 2; }
EOF
}

@test "tier2: line deleted on base and re-added on branch yields RESURRECT" {
  seed_deleted_line_on_main
  readd_deleted_line
  commit_all resurrect
  run --separate-stderr bash "$TIER2" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER2-RESULT: RESURRECT files=1 lines=1" ]
}

@test "tier2: uncommitted re-add is detected too" {
  # normal モードの diff は作業ツリー込み(未コミットも self-review の対象)。
  seed_deleted_line_on_main
  readd_deleted_line
  run --separate-stderr bash "$TIER2" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER2-RESULT: RESURRECT files=1 lines=1" ]
}

@test "tier2: line re-added on base as well yields OK" {
  # base-tip に現存する行は「base が正当に戻した」ので復活ではない。
  seed_deleted_line_on_main
  readd_deleted_line
  commit_all branch-readd
  git -C "$REPO" checkout -q main
  readd_deleted_line
  commit_all base-readd
  git -C "$REPO" checkout -q work
  run --separate-stderr bash "$TIER2" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER2-RESULT: OK(復活コードなし)" ]
}

@test "tier2: brand-new line yields OK" {
  seed_deleted_line_on_main
  write_file src/app.js <<'EOF'
function head() { return 1; }
const brandNewThing = makeSomething(gamma);
function tail() { return 2; }
EOF
  commit_all fresh
  run --separate-stderr bash "$TIER2" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER2-RESULT: OK(復活コードなし)" ]
}

@test "tier2: no added lines yields OK" {
  seed_deleted_line_on_main
  run --separate-stderr bash "$TIER2" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER2-RESULT: OK(ブランチ側に追加行なし)" ]
}

@test "tier2: short noise line is not counted as resurrect" {
  # 8 文字未満 / 英数字なしの行はノイズ除去で対象外(閉じ括弧の一致等を拾わない)。
  write_file src/app.js <<'EOF'
const alphaValue = computeOne(x);
}
const betaValue = computeTwo(y);
EOF
  commit_all c1
  # base が削除するのは記号だけの行。
  write_file src/app.js <<'EOF'
const alphaValue = computeOne(x);
const betaValue = computeTwo(y);
EOF
  commit_all c2
  git -C "$REPO" checkout -q -b work
  write_file src/app.js <<'EOF'
const alphaValue = computeOne(x);
}
const betaValue = computeTwo(y);
const brandNewThing = makeSomething(gamma);
EOF
  commit_all readd-noise
  run --separate-stderr bash "$TIER2" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER2-RESULT: OK(復活コードなし)" ]
}

@test "tier2: quoted path on the added side yields SKIP not OK" {
  # a/ b/ 剥がしが効かず照合不能。細工ファイル名での無音バイパスを SKIP で塞ぐ。
  write_file src/app.js <<'EOF'
function head() { return 1; }
EOF
  commit_all c1
  git -C "$REPO" checkout -q -b work
  write_file 'src/qu"oted.js' <<'EOF'
const somethingLongEnough = doWork(delta);
EOF
  commit_all quoted
  run --separate-stderr bash "$TIER2" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER2-RESULT: SKIP(ブランチ追加側に解釈不能なパス(C-quote)あり)" ]
}

@test "tier2: invalid TIER2_WINDOW yields SKIP" {
  seed_deleted_line_on_main
  readd_deleted_line
  run --separate-stderr env TIER2_WINDOW=abc bash "$TIER2" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER2-RESULT: SKIP(TIER2_WINDOW 不正: abc)" ]
}

@test "tier2: corrupt lib yields SKIP" {
  seed_deleted_line_on_main
  readd_deleted_line
  printf 'if [ ; then\n' >"$LIB/resolve-base-ref.sh"
  run --separate-stderr bash "$TIER2" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER2-RESULT: SKIP(lib 破損: resolve-base-ref.sh)" ]
}

@test "tier2: missing lib yields SKIP" {
  seed_deleted_line_on_main
  readd_deleted_line
  rm -f "$LIB/resolve-base-ref.sh"
  run --separate-stderr bash "$TIER2" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER2-RESULT: SKIP(lib 不達: resolve-base-ref.sh)" ]
}

@test "tier2: no protected ancestor yields SKIP" {
  seed_deleted_line_on_main
  readd_deleted_line
  git -C "$REPO" branch -D main
  run --separate-stderr bash "$TIER2" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER2-RESULT: SKIP(base 解決不能(保護祖先なし))" ]
}

@test "tier2: outside a git repo yields SKIP" {
  run --separate-stderr bash "$TIER2" "$(plain_dir)"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  assert_last_line_prefix "TIER2-RESULT: SKIP(git repo 外: "
}

@test "tier2: triple mode with unknown ref yields SKIP" {
  seed_deleted_line_on_main
  run --separate-stderr bash "$TIER2" --triple 0000000000000000000000000000000000000000 main HEAD "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER2-RESULT: SKIP(ref 不正: 0000000000000000000000000000000000000000)" ]
}

@test "tier2: triple mode detects resurrect in the committed range" {
  seed_deleted_line_on_main
  local mb
  mb="$(git -C "$REPO" rev-parse HEAD)"
  readd_deleted_line
  commit_all resurrect
  run --separate-stderr bash "$TIER2" --triple "$mb" main HEAD "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER2-RESULT: RESURRECT files=1 lines=1" ]
}

# ── Tier 3: scope-deviation-check.sh ────────────────────────────────────────

# work ブランチと、src/ + home/ の変更を用意する。
seed_scope_repo() {
  write_file src/app.js <<'EOF'
function head() { return 1; }
EOF
  write_file home/x.sh <<'EOF'
echo hi
EOF
  commit_all init
  git -C "$REPO" checkout -q -b work
  write_file src/app.js <<'EOF'
function head() { return 2; }
EOF
}

# 宣言スコープフラグの絶対パス(lib 経由でキーを引く)。
scope_flag_path() {
  local repo
  repo="$("$LIB/resolve-repo-key.sh" "$REPO")"
  "$LIB/flag-paths.sh" design-scope "$repo" work
}

scope_pending_path() {
  local repo
  repo="$("$LIB/resolve-repo-key.sh" "$REPO")"
  "$LIB/flag-paths.sh" design-scope-pending "$repo"
}

# write_scope <フラグパス>  … パターンは stdin(1 行 1 path/glob)。
write_scope() {
  mkdir -p "$(dirname "$1")"
  cat >"$1"
}

@test "tier3: no scope declaration yields SKIP not OK" {
  seed_scope_repo
  run --separate-stderr bash "$TIER3" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER3-RESULT: SKIP(スコープ宣言なし(design-review 未実施 or 宣言なしで通過))" ]
}

@test "tier3: change inside declared scope yields OK" {
  seed_scope_repo
  write_scope "$(scope_flag_path)" <<'EOF'
src/*
EOF
  run --separate-stderr bash "$TIER3" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER3-RESULT: OK(宣言スコープ内)" ]
}

@test "tier3: change outside declared scope yields DEVIATION" {
  seed_scope_repo
  write_scope "$(scope_flag_path)" <<'EOF'
home/*
EOF
  run --separate-stderr bash "$TIER3" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER3-RESULT: DEVIATION files=1" ]
}

@test "tier3: untracked file outside scope counts as DEVIATION" {
  # 新規ファイルの作成は乖離の典型だが diff --name-only には出ないため untracked も見る。
  seed_scope_repo
  write_scope "$(scope_flag_path)" <<'EOF'
src/*
EOF
  write_file notes/plan.md <<'EOF'
memo
EOF
  run --separate-stderr bash "$TIER3" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER3-RESULT: DEVIATION files=1" ]
}

@test "tier3: pending scope flag is used when the branch flag is absent" {
  seed_scope_repo
  write_scope "$(scope_pending_path)" <<'EOF'
home/*
EOF
  run --separate-stderr bash "$TIER3" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER3-RESULT: DEVIATION files=1" ]
}

@test "tier3: stale pending scope flag over 24h yields SKIP" {
  seed_scope_repo
  local p
  p="$(scope_pending_path)"
  write_scope "$p" <<'EOF'
home/*
EOF
  touch -t 202001010000 "$p"
  run --separate-stderr bash "$TIER3" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER3-RESULT: SKIP(スコープ宣言なし(design-review 未実施 or 宣言なしで通過))" ]
}

@test "tier3: branch scope flag has no freshness limit" {
  # 鮮度 24h は pending だけの規則。branch 版は古くてもそのまま使う。
  seed_scope_repo
  local f
  f="$(scope_flag_path)"
  write_scope "$f" <<'EOF'
home/*
EOF
  touch -t 202001010000 "$f"
  run --separate-stderr bash "$TIER3" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER3-RESULT: DEVIATION files=1" ]
}

@test "tier3: symlinked scope flag is ignored" {
  seed_scope_repo
  local real="$BATS_TEST_TMPDIR/real-scope.txt"
  printf 'src/*\n' >"$real"
  local f
  f="$(scope_flag_path)"
  mkdir -p "$(dirname "$f")"
  ln -sf "$real" "$f"
  run --separate-stderr bash "$TIER3" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER3-RESULT: SKIP(スコープ宣言なし(design-review 未実施 or 宣言なしで通過))" ]
}

@test "tier3: missing lib yields SKIP" {
  seed_scope_repo
  write_scope "$(scope_flag_path)" <<'EOF'
src/*
EOF
  rm -f "$LIB/flag-paths.sh"
  run --separate-stderr bash "$TIER3" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(last_line)" = "TIER3-RESULT: SKIP(lib 不達: flag-paths.sh)" ]
}

@test "tier3: outside a git repo yields SKIP" {
  run --separate-stderr bash "$TIER3" "$(plain_dir)"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  assert_last_line_prefix "TIER3-RESULT: SKIP(git repo 外: "
}
