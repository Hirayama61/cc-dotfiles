#!/usr/bin/env bash
# bats 共通ヘルパ。
#
# hooks は実行時に lib を $HOME/.claude/hooks/lib/ の apply 先絶対パスで参照するため、
# テストは一時 HOME(BATS_TEST_TMPDIR 配下)に hooks/lib を複製し、chezmoi の
# private_executable_ / executable_ プレフィックスを剥がして chmod +x し、HOME を
# 差し替えて実行する。これにより本物の ~/.claude には一切触れない。
#
# 注意(flag dir): flag-paths.sh の claude_flag_dir() は /tmp/claude-sessions 固定で
# HOME 非依存。フラグ書込は ctx(session_id/transcript_path)依存のため、テストの入力
# JSON に session_id を含めなければ /tmp への副作用は出ない。Phase 4(#49)で
# XDG_STATE_HOME 配下へ移すと HOME 差し替えに追従し、この隔離が構造的に保証される。

# このヘルパ自身の位置からリポルートを導出(tests/helpers/common.bash)。
HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HELPER_DIR/../.." && pwd)"
HOOKS_SRC="$REPO_ROOT/home/dot_claude/hooks"

# 一時 HOME に hooks と lib を複製し、HOME を差し替える。
install_hooks() {
  export TEST_HOME="$BATS_TEST_TMPDIR/home"
  local dst="$TEST_HOME/.claude/hooks"
  mkdir -p "$dst/lib"

  local f base
  # lib(executable_ プレフィックス)
  for f in "$HOOKS_SRC"/lib/executable_*.sh; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    base="${base#executable_}"
    cp "$f" "$dst/lib/$base"
    chmod +x "$dst/lib/$base"
  done
  # hooks(private_executable_ プレフィックス)
  for f in "$HOOKS_SRC"/private_executable_*.sh; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    base="${base#private_executable_}"
    cp "$f" "$dst/$base"
    chmod +x "$dst/$base"
  done

  export HOME="$TEST_HOME"
}

# install 済み hook 名(.sh 付き)の一覧を1行1名で出す。
list_installed_hooks() {
  local f
  for f in "$HOME/.claude/hooks"/*.sh; do
    [[ -e "$f" ]] || continue
    basename "$f"
  done
}

# 内部: 指定 PATH で hook を実行し、グローバル status / output を設定する。
# bats の `run` を使わず自前で status を取るのは、jq 不在 hook の exit 127 で
# bats が出す BW01 警告(command-not-found 助言)を避けるため。stdout/stderr を
# 混ぜて output に入れ、ブロックメッセージの検証に使えるようにする。
#
# 実行 cwd を BATS_TEST_TMPDIR(非 git・一時領域)に固定する。hook の一部は入力 JSON に
# cwd が無いと $PWD へフォールバックして実 repo を判定する(例 block-unreviewed-plan が
# design-gate 状態を見る)。固定しないとテスト実行ディレクトリの repo 状態に依存して
# 環境ごとに結果が変わる(CI とローカルで挙動が割れる)。非 repo に固定すれば
# cwd 未指定入力でも fail-open(repo 不明 → exit 0)で決定的になる。
_run_hook_impl() {
  local path_val="$1" hook="$2" json="$3"
  # cwd 固定の前提(BATS_TEST_TMPDIR が有効な非 repo dir であること)を厳格に確認する。
  # silent な cd 失敗は実 repo で hook を走らせ環境依存へ戻すため、無効なら即失敗させる。
  if [[ ! -d "$BATS_TEST_TMPDIR" ]]; then
    echo "ERROR: BATS_TEST_TMPDIR が未設定/無効。cwd 固定が無効化される" >&2
    status=1
    output="BATS_TEST_TMPDIR invalid"
    return 1
  fi
  set +e
  output="$(cd "$BATS_TEST_TMPDIR" && PATH="$path_val" bash -c 'printf "%s" "$2" | "$1"' _ "$hook" "$json" 2>&1)"
  status=$?
  set -e
}

# run_hook <hook名.sh> [JSON文字列]
# 現 PATH で stdin に JSON を流して hook を実行。$status / $output を設定。
run_hook() {
  _run_hook_impl "$PATH" "$HOME/.claude/hooks/$1" "${2:-}"
}

# run_hook_env <PATH値> <hook名.sh> [JSON文字列]
# PATH を差し替えて hook を実行(jq 不在 shim 等)。
run_hook_env() {
  _run_hook_impl "$1" "$HOME/.claude/hooks/$2" "${3:-}"
}

# jq だけを欠落させた shim PATH を作って出力する。
# 必要コマンドは実体へ symlink して残し、jq だけ含めない。
# 注: 列挙は手書きホワイトリスト。hook が将来新コマンド(realpath/shasum 等)を使い始めると
# 「jq 不在」でなく「別コマンド不在」で別経路に入りうる(現状 hook の外部依存は jq/gh のみ
# =実測)。判定が exit!=2 のみのため列挙漏れは検知しにくい点に留意。
make_no_jq_path() {
  local shim="$BATS_TEST_TMPDIR/nojq-bin"
  mkdir -p "$shim"
  local c p
  for c in bash sh env cat printf echo grep egrep sed tr cut awk \
    basename dirname git mkdir rmdir rm cp mv touch ln find sort comm uniq \
    date stat wc head tail xargs test true false; do
    p="$(command -v "$c" 2>/dev/null)" || continue
    ln -sf "$p" "$shim/$c"
  done
  printf '%s' "$shim"
}
