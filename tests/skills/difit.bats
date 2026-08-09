#!/usr/bin/env bats
# difit skill の 2 スクリプトの**最終行契約**と破壊的操作の安全条件を固定する:
#   - build-launch.sh … 状態判定 / base 解決 / rev 検証 / 起動コマンド組み立て
#   - teardown.sh     … index 復元(intent-to-add の巻き戻し)+ サーバ停止
#
# 呼び出し側(difit skill)が機械解釈するのは最終行と LAUNCH-CMD 行だけなので、検証も
# そこへ寄せる。特に「引数と stdout だけで状態を受け渡す」設計を守るため、untracked 一覧は
# build-launch が書いたファイルのパスが最終行に出ること、teardown がそのパスだけを見て
# 復元することを固定する。
#
# common.bash の install_hooks で一時 HOME に hooks/lib(executable_ を剥がす)を複製し
# HOME を差し替える(build-launch は $HOME/.claude/hooks/lib/resolve-base-ref.sh を実行時
# 参照する)。判定対象の repo は BATS_TEST_TMPDIR 配下の一時 git repo。
#
# `run --separate-stderr` は bats 1.5.0 以降。宣言しないと BW02 警告が出る。
bats_require_minimum_version 1.5.0

load ../helpers/common

setup() {
  # 継承環境の GIT_* は repo の位置・diff の実装・config 注入のいずれにも効く。列挙は
  # 取りこぼすので一掃してから必要な 2 本だけ張り直す(vanish-detection.bats と同作法)。
  for v in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  install_hooks
  unset XDG_STATE_HOME
  # スクリプトは mktemp で untracked 一覧等を作る。実 TMPDIR に残骸を残さないよう
  # bats のテスト専用一時領域へ寄せる(common.bash の「本物の環境に触れない」作法)。
  export TMPDIR="$BATS_TEST_TMPDIR"

  SHIM="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$SHIM"
  # resolve_base_ref の手順 1 は gh で PR base を引く。実 gh の認証状態やネットワークで
  # 結果が揺れないよう、常に失敗する shim を PATH 先頭に置き merge-base フォールバック
  # 経路(手順 2)に固定する。
  printf '#!/bin/sh\nexit 1\n' >"$SHIM/gh"
  # build-launch は difit の実在を確認してから起動コマンドを出す。CI/開発機に difit が
  # 入っていなくても状態判定の検証ができるよう、何もしない shim を置く。
  printf '#!/bin/sh\nexit 0\n' >"$SHIM/difit"
  chmod +x "$SHIM/gh" "$SHIM/difit"
  export PATH="$SHIM:$PATH"

  local scripts="$REPO_ROOT/home/dot_claude/skills/difit/scripts"
  BUILD="$scripts/executable_build-launch.sh"
  TEARDOWN="$scripts/executable_teardown.sh"

  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" checkout -q -b main
  printf 'a\n' >"$REPO/a.txt"
  git -C "$REPO" add a.txt
  gcommit "$REPO" init
}

# グローバル pre-commit(Conventional Commits 検査)に止められないよう hooksPath を無効化する。
gcommit() {
  git -C "$1" -c user.name=t -c user.email=t@example.com -c core.hooksPath=/dev/null \
    commit -q -m "$2"
}

# 機械解釈の対象になる最終行だけを取り出す。`run --separate-stderr` と対で使う。
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

# 最終行の `untracked=` の値を取り出す。
untracked_path() {
  printf '%s\n' "$output" | sed -n 's/^LAUNCH-RESULT: READY .*untracked=//p' | tail -n 1
}

# 出力全体の部分一致(LAUNCH-CMD の中身検査などに使う)。
# `case` のパターン内でも二重引用符で囲んだ展開は glob 展開されず literal 照合になる
# (bash 3.2 で実測)。needle に `?` `*` `[` が入っても意図どおり効く。
assert_output_contains() {
  case "$output" in
  *"$1"*) return 0 ;;
  esac
  printf 'expected substring: %s\n' "$1" >&2
  printf 'actual output     :\n%s\n' "$output" >&2
  return 1
}

# 出力に「この 1 行」が丸ごと在ることを固定する(全文一致)。部分一致だと LAUNCH-CMD の
# 引数順の入れ替えや `&&` → `;` の書式退化を素通しするので、機械解釈される行はこちらで見る。
# while 本体はリダイレクト先が here-string でも現シェルで走るため、中の return が効く。
assert_output_has_line() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || {
    printf 'usage: assert_output_has_line <non-empty-line>\n' >&2
    return 2
  }
  local line
  while IFS= read -r line; do
    [ "$line" = "$1" ] && return 0
  done <<<"$output"
  printf 'expected line: %s\n' "$1" >&2
  printf 'actual output:\n%s\n' "$output" >&2
  return 1
}

# feat ブランチを切って 1 コミット進める(未 push コミットあり状態を作る)。
advance_branch() {
  git -C "$REPO" checkout -q -b feat/x
  printf 'b\n' >>"$REPO/a.txt"
  git -C "$REPO" add a.txt
  gcommit "$REPO" change
}

# ---- build-launch: 引数ガード ----

@test "build-launch rejects an empty repo argument instead of falling back to cwd" {
  # `git -C ""` は rc=0 で cwd にフォールバックする。cwd を有効な repo に置いた状態で
  # 空文字を渡し、cwd の repo を勝手に対象にしないことを固定する。
  cd "$REPO"
  run --separate-stderr bash "$BUILD" ""
  [ "$status" -ne 0 ]
  assert_last_line_prefix "LAUNCH-RESULT: ERROR"
}

@test "build-launch rejects a path that is not a git work tree" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run --separate-stderr bash "$BUILD" "$BATS_TEST_TMPDIR/plain"
  [ "$status" -ne 0 ]
  assert_last_line_prefix "LAUNCH-RESULT: ERROR"
}

# ---- build-launch: rev 検証 ----

@test "build-launch accepts explicit revs that git can verify" {
  # `git rev-parse --verify -- <rev>` は `--` が pathspec 区切りなので正当な rev でも
  # 失敗する。正しい形(--quiet --end-of-options + ^{commit})を使っていることを固定する。
  advance_branch
  run --separate-stderr bash "$BUILD" "$REPO" branch HEAD main
  [ "$status" -eq 0 ]
  assert_last_line_prefix "LAUNCH-RESULT: READY mode=branch"
  # 全文一致。target/base の入れ替え(difit は base が第 2 引数)、`&&` → `;` の退化
  # (cd が失敗しても difit が呼び出し側の cwd で走る)、--merge-base の脱落を同時に塞ぐ。
  assert_output_has_line "LAUNCH-CMD: cd '$REPO' && difit 'HEAD' 'main' --merge-base --clean"
}

@test "build-launch rejects a rev that does not exist" {
  advance_branch
  run --separate-stderr bash "$BUILD" "$REPO" branch HEAD nosuchref
  [ "$status" -ne 0 ]
  assert_last_line_prefix "LAUNCH-RESULT: ERROR"
}

@test "build-launch rejects an option-like rev" {
  advance_branch
  run --separate-stderr bash "$BUILD" "$REPO" branch HEAD "--upload-pack=touch /tmp/pwn"
  [ "$status" -ne 0 ]
  assert_last_line_prefix "LAUNCH-RESULT: ERROR"
}

@test "build-launch rejects range notation because difit takes two arguments" {
  advance_branch
  run --separate-stderr bash "$BUILD" "$REPO" branch "main...HEAD"
  [ "$status" -ne 0 ]
  assert_last_line_prefix "LAUNCH-RESULT: ERROR"
}

@test "build-launch rejects commit mode and a lone target rev" {
  # SKILL.md の手順が渡すのは repo / worktree / branch / branch <target> <base> の 4 形だけ。
  # 入口の無い mode を受理すると、呼ばれない分岐が腐って残る。
  advance_branch
  run --separate-stderr bash "$BUILD" "$REPO" commit HEAD
  [ "$status" -ne 0 ]
  assert_last_line_prefix "LAUNCH-RESULT: ERROR"
  run --separate-stderr bash "$BUILD" "$REPO" auto HEAD
  [ "$status" -ne 0 ]
  assert_last_line_prefix "LAUNCH-RESULT: ERROR"
}

@test "build-launch rejects a dot target because worktree mode is spelled out" {
  printf 'dirty\n' >>"$REPO/a.txt"
  run --separate-stderr bash "$BUILD" "$REPO" auto "."
  [ "$status" -ne 0 ]
  assert_last_line_prefix "LAUNCH-RESULT: ERROR"
}

# ---- build-launch: --clean の抑止 ----

@test "build-launch drops the clean flag in worktree mode when asked" {
  # 落とし穴 10(--clean が preload コメントを消す疑い)の回避経路。SKILL.md は
  # LAUNCH-CMD 行をそのまま実行する契約なので、手で削らせず組み立て側で落とす。
  printf 'dirty\n' >>"$REPO/a.txt"
  run --separate-stderr bash "$BUILD" "$REPO" --no-clean
  [ "$status" -eq 0 ]
  assert_last_line_prefix "LAUNCH-RESULT: READY mode=worktree"
  assert_output_has_line "LAUNCH-CMD: cd '$REPO' && difit . --include-untracked"
}

@test "build-launch drops the clean flag in branch mode when asked" {
  advance_branch
  run --separate-stderr bash "$BUILD" "$REPO" branch HEAD main --no-clean
  [ "$status" -eq 0 ]
  assert_last_line_prefix "LAUNCH-RESULT: READY mode=branch"
  assert_output_has_line "LAUNCH-CMD: cd '$REPO' && difit 'HEAD' 'main' --merge-base"
}

# ---- build-launch: 状態判定 ----

@test "build-launch resolves base for a clean tree with unpushed commits" {
  # base 解決を「HEAD <base> 形を選んだときだけ」にすると状態判定に必要な
  # rev-list --count が回らない。auto でも base を解決してから判定することを固定する。
  advance_branch
  run --separate-stderr bash "$BUILD" "$REPO"
  [ "$status" -eq 0 ]
  assert_last_line_prefix "LAUNCH-RESULT: READY mode=branch"
  assert_output_contains "untracked=-"
  assert_output_has_line "LAUNCH-CMD: cd '$REPO' && difit 'HEAD' 'main' --merge-base --clean"
}

@test "build-launch picks worktree mode when only uncommitted changes exist" {
  printf 'dirty\n' >>"$REPO/a.txt"
  run --separate-stderr bash "$BUILD" "$REPO"
  [ "$status" -eq 0 ]
  assert_last_line_prefix "LAUNCH-RESULT: READY mode=worktree"
  assert_output_has_line "LAUNCH-CMD: cd '$REPO' && difit . --include-untracked --clean"
}

@test "build-launch reports ambiguous when both worktree and branch diffs exist" {
  advance_branch
  printf 'dirty\n' >>"$REPO/a.txt"
  run --separate-stderr bash "$BUILD" "$REPO"
  [ "$status" -eq 0 ]
  assert_last_line_prefix "LAUNCH-RESULT: AMBIGUOUS"
}

@test "build-launch honours an explicit mode when the state is ambiguous" {
  advance_branch
  printf 'dirty\n' >>"$REPO/a.txt"
  run --separate-stderr bash "$BUILD" "$REPO" worktree
  [ "$status" -eq 0 ]
  assert_last_line_prefix "LAUNCH-RESULT: READY mode=worktree"
}

@test "build-launch reports empty when there is nothing to show" {
  run --separate-stderr bash "$BUILD" "$REPO"
  [ "$status" -eq 0 ]
  assert_last_line_prefix "LAUNCH-RESULT: EMPTY"
}

@test "build-launch errors on a clean tree whose base cannot be resolved" {
  # 保護ブランチが 1 本も無い repo。base 不明のまま EMPTY と言うと「差分なし」の
  # 誤結論になるので ERROR に倒す。
  local orphan="$BATS_TEST_TMPDIR/orphan"
  mkdir -p "$orphan"
  git -C "$orphan" init -q
  git -C "$orphan" checkout -q -b feat/solo
  printf 'x\n' >"$orphan/x.txt"
  git -C "$orphan" add x.txt
  gcommit "$orphan" init
  run --separate-stderr bash "$BUILD" "$orphan"
  [ "$status" -ne 0 ]
  assert_last_line_prefix "LAUNCH-RESULT: ERROR"
}

@test "build-launch records the untracked list before difit touches the index" {
  printf 'u\n' >"$REPO/u.txt"
  run --separate-stderr bash "$BUILD" "$REPO"
  [ "$status" -eq 0 ]
  assert_last_line_prefix "LAUNCH-RESULT: READY mode=worktree"
  # 件数の行と一覧パスの行でキー名が衝突していないこと。同名(untracked=)だと、
  # 手順 5 へ渡す値として件数の方を拾って teardown が一覧不達で復元できない。
  assert_output_contains "LAUNCH: untracked_count=1"
  [ "$(printf '%s\n' "$output" | grep -c '^LAUNCH: untracked=')" -eq 0 ]
  local ul
  ul="$(untracked_path)"
  [ -n "$ul" ]
  [ "$ul" != "-" ]
  [ -f "$ul" ]
  # 実 TMPDIR を汚さない(テストは一時領域だけで完結する)。
  case "$ul" in
  "$BATS_TEST_TMPDIR"/*) : ;;
  *)
    printf 'untracked list escaped the test tmpdir: %s\n' "$ul" >&2
    return 1
    ;;
  esac
  run --separate-stderr tr '\0' '\n' <"$ul"
  assert_output_contains "u.txt"
}

# ---- teardown: index 復元 ----

@test "teardown keeps unrelated staged changes when the untracked list is empty" {
  # `git reset -- <一覧>` は一覧が空だと pathspec 無しの mixed reset になり、difit と
  # 無関係な staged 変更まで全部 unstage する。空一覧では reset を撃たないことを固定する。
  printf 'staged\n' >"$REPO/s.txt"
  git -C "$REPO" add s.txt
  local ul="$BATS_TEST_TMPDIR/empty.list"
  : >"$ul"
  run --separate-stderr bash "$TEARDOWN" "$REPO" "$ul" -
  [ "$status" -eq 0 ]
  assert_last_line_prefix "TEARDOWN-RESULT: DONE"
  run --separate-stderr git -C "$REPO" status --porcelain -- s.txt
  assert_output_contains "A  s.txt"
}

@test "teardown unstages only the recorded intent-to-add files" {
  # difit 起動時点の状態: s.txt は既に staged、u.txt は untracked。一覧は untracked だけを
  # 拾うので、復元も u.txt だけに当たらなければならない。
  printf 'staged\n' >"$REPO/s.txt"
  git -C "$REPO" add s.txt
  printf 'u\n' >"$REPO/u.txt"
  local ul="$BATS_TEST_TMPDIR/u.list"
  git -C "$REPO" ls-files -z --others --exclude-standard >"$ul"
  # difit の --include-untracked 相当。
  git -C "$REPO" add --intent-to-add u.txt
  run --separate-stderr bash "$TEARDOWN" "$REPO" "$ul" -
  [ "$status" -eq 0 ]
  assert_last_line_prefix "TEARDOWN-RESULT: DONE"
  run --separate-stderr git -C "$REPO" status --porcelain
  assert_output_contains "?? u.txt"
  assert_output_contains "A  s.txt"
}

@test "teardown treats recorded paths as literal instead of pathspec magic" {
  # `git reset -- <path>` の `--` はオプション解釈を止めるだけで、先頭 `:` の pathspec
  # magic は生きている。`:` という名の untracked が 1 つあると repo 全体が対象になり、
  # difit と無関係な index まで巻き戻る(`:!keep.txt` なら「keep.txt 以外を全部」)。
  printf 'k\n' >"$REPO/keep.txt"
  printf 'o\n' >"$REPO/other.txt"
  git -C "$REPO" add keep.txt other.txt
  printf 'x\n' >"$REPO/:"
  printf 'y\n' >"$REPO/:!keep.txt"
  local ul="$BATS_TEST_TMPDIR/magic.list"
  git -C "$REPO" ls-files -z --others --exclude-standard >"$ul"
  # difit の --include-untracked 相当(記録した 2 本だけを intent-to-add)。
  GIT_LITERAL_PATHSPECS=1 git -C "$REPO" add --intent-to-add -- ':' ':!keep.txt'
  # 一覧に無い intent-to-add。magic が効くとここまで巻き添えで消える。
  printf 'l\n' >"$REPO/later.txt"
  git -C "$REPO" add --intent-to-add later.txt
  run --separate-stderr bash "$TEARDOWN" "$REPO" "$ul" -
  [ "$status" -eq 0 ]
  assert_last_line_prefix "TEARDOWN-RESULT: DONE"
  run --separate-stderr git -C "$REPO" status --porcelain
  assert_output_has_line "A  keep.txt"
  assert_output_has_line "A  other.txt"
  assert_output_has_line " A later.txt"
  assert_output_has_line "?? :"
  assert_output_has_line "?? :!keep.txt"
}

@test "teardown keeps files the human staged after launch" {
  # 一覧は起動時点の untracked。その後に人間が本当に `git add` したものまで unstage すると
  # staged 内容が index から落ちる。porcelain の ` A`(intent-to-add)だけを戻す。
  printf 'u\n' >"$REPO/u.txt"
  printf 'n\n' >"$REPO/new.txt"
  local ul="$BATS_TEST_TMPDIR/u.list"
  git -C "$REPO" ls-files -z --others --exclude-standard >"$ul"
  git -C "$REPO" add --intent-to-add u.txt new.txt
  # 起動後に人間が意図して add した。
  git -C "$REPO" add new.txt
  run --separate-stderr bash "$TEARDOWN" "$REPO" "$ul" -
  [ "$status" -eq 0 ]
  assert_last_line_prefix "TEARDOWN-RESULT: DONE"
  run --separate-stderr git -C "$REPO" status --porcelain
  assert_output_has_line "?? u.txt"
  assert_output_has_line "A  new.txt"
}

@test "teardown does not read a rename old path as an entry" {
  # `git status --porcelain -z` の rename は「新パス\0旧パス\0」の 2 フィールド(両側が
  # pathspec に入った時に出る)。旧パスを読み捨てないと、旧パスそのものが 1 エントリとして
  # 解釈される。先頭 2 文字が " A" のパス名だと intent-to-add と誤認され、その 3 文字目
  # 以降(ここでは x.txt)が巻き添えで unstage される。
  printf 'v\n' >"$REPO/ A x.txt"
  git -C "$REPO" add -- " A x.txt"
  gcommit "$REPO" weird
  printf 'x\n' >"$REPO/x.txt"
  git -C "$REPO" add x.txt
  printf 'u\n' >"$REPO/u.txt"
  git -C "$REPO" add --intent-to-add u.txt
  git -C "$REPO" mv -- " A x.txt" dest.txt
  local ul="$BATS_TEST_TMPDIR/rename.list"
  printf ' A x.txt\0dest.txt\0u.txt\0' >"$ul"
  run --separate-stderr bash "$TEARDOWN" "$REPO" "$ul" -
  [ "$status" -eq 0 ]
  assert_last_line_prefix "TEARDOWN-RESULT: DONE"
  run --separate-stderr git -C "$REPO" status --porcelain
  assert_output_has_line "A  x.txt"
  assert_output_has_line "?? u.txt"
}

@test "teardown skips index restore when the repo argument is empty" {
  cd "$REPO"
  local ul="$BATS_TEST_TMPDIR/u.list"
  printf 'u.txt\0' >"$ul"
  run --separate-stderr bash "$TEARDOWN" "" "$ul" -
  [ "$status" -ne 0 ]
  assert_last_line_prefix "TEARDOWN-RESULT: ERROR"
}

# ---- teardown: サーバ停止 ----

@test "teardown skips a non numeric port instead of running lsof" {
  # 「pwn ファイルが無いこと」は主張にならない(port は一度もシェル評価されないので
  # 元から作られえない)。数値ガードで弾いたという理由そのものを固定する。
  # ガードを外すと lsof まで進み「listener なし」の別行になる。
  run --separate-stderr bash "$TEARDOWN" - - "abc; touch $BATS_TEST_TMPDIR/pwn"
  [ "$status" -eq 0 ]
  assert_last_line_prefix "TEARDOWN-RESULT: DONE"
  assert_output_contains "TEARDOWN: server skip(port が不正"
}

@test "teardown does not kill a listener that is not difit" {
  # bats は背景プロセスが stdout/stderr を掴んだままだと結果収集で待つので FD を切る。
  sleep 120 >/dev/null 2>&1 <&- &
  local victim=$!
  printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "$victim" >"$SHIM/lsof"
  printf '#!/bin/sh\nprintf "sleep 120\\n"\n' >"$SHIM/ps"
  chmod +x "$SHIM/lsof" "$SHIM/ps"
  run --separate-stderr bash "$TEARDOWN" - - 4966
  [ "$status" -eq 0 ]
  assert_last_line_prefix "TEARDOWN-RESULT: DONE"
  kill -0 "$victim"
  # kill 直後に wait で回収しないと、シェルがジョブ終了を非同期に報告して TAP 出力へ混ざる。
  { kill "$victim" && wait "$victim"; } >/dev/null 2>&1 || true
}

@test "teardown kills a listener whose command line is difit" {
  sleep 120 >/dev/null 2>&1 <&- &
  local target=$!
  printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "$target" >"$SHIM/lsof"
  printf '#!/bin/sh\nprintf "node /opt/difit/dist/cli/index.js\\n"\n' >"$SHIM/ps"
  chmod +x "$SHIM/lsof" "$SHIM/ps"
  run --separate-stderr bash "$TEARDOWN" - - 4966
  [ "$status" -eq 0 ]
  assert_last_line_prefix "TEARDOWN-RESULT: DONE"
  # SIGTERM の反映を待つ(kill は非同期)。
  local i=0
  while kill -0 "$target" 2>/dev/null && [ "$i" -lt 50 ]; do
    i=$((i + 1))
    sleep 0.1
  done
  run --separate-stderr kill -0 "$target"
  [ "$status" -ne 0 ]
  wait "$target" >/dev/null 2>&1 || true
}
