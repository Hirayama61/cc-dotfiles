#!/usr/bin/env bash
# finish-state.sh — state file の確定(compact-prep 手順 7)
#
# 構造検証を通った state file に鮮度スタンプ(state-stamp)を打つ。スタンプが
# 打たれて初めて precompact-gate と stop-nudge がその state を「新鮮」と見る。
#
# スタンプが証明するのは構造検証まで。決定ログ突合や独立検証を実施したかは
# 自己申告で、失敗方向は安全側(偽の新鮮は作れるが偽の古さは作らない)。
#
# ctx キーはモデルに推測させない: 引数の state file が置かれたディレクトリ名を
# ctx とみなす。書込に加えて削除も行うため、cache 直下であること・basename が
# state.md であること・usage.json が読めるならその transcript_path が同じ ctx を
# 指すことを検査してから使う。**取り違えを完全には防げない** — usage.json が無い
# 窓(圧縮直後)では ctx の一致を確かめる材料が無く、cache 直下の別セッションの
# ディレクトリを渡されれば受理する。
#
# 出力: PASS / FAIL(理由付き)。exit 0 = PASS、exit 1 = FAIL。
# validate-state.sh と同じく exit 2 は使わない(PreToolUse のブロックと紛れさせない)。
set -euo pipefail

state="${1:-}"
fail() {
  echo "FAIL: $1"
  exit 1
}

[[ -n "$state" ]] || fail "state file のパスが指定されていない"

LIB="$HOME/.claude/hooks/lib/context-paths.sh"
[[ -r "$LIB" ]] || fail "context-paths.sh が読めない: $LIB"
# shellcheck source=/dev/null
(. "$LIB") >/dev/null 2>&1 || fail "context-paths.sh の読込に失敗した: $LIB"
# shellcheck source=/dev/null
. "$LIB" || fail "context-paths.sh の読込に失敗した: $LIB"
# apply 前後で lib が古いままだと、原因と無関係なエラーで落ちて読み解けなくなる
type ctx_state_stamp_file claude_ctx_state_stamp_line >/dev/null 2>&1 ||
  fail "context-paths.sh が古い(鮮度スタンプの関数が無い)。dotfiles から適用し直すこと"
command -v jq >/dev/null 2>&1 || fail "jq が無い"

[[ "$(basename -- "$state")" == "state.md" ]] || fail "state file の名前が state.md ではない: $state"

ctx_dir="$(cd -- "$(dirname -- "$state")" 2>/dev/null && pwd -P || true)"
[[ -n "$ctx_dir" ]] || fail "state file のディレクトリが解決できない: $state"
cache_base="$(cd -- "$(claude_ctx_cache_base)" 2>/dev/null && pwd -P || true)"
[[ -n "$cache_base" ]] || fail "cache 基底ディレクトリが存在しない"
[[ "$(dirname -- "$ctx_dir")" == "$cache_base" ]] || fail "state file が cache 直下の ctx ディレクトリにない: $state"

ctx="$(basename -- "$ctx_dir")"
# パスは lib の accessor から引く(ファイル名を直書きすると、lib 側を変えたときに
# 書き手と読み手がずれてスタンプが誰にも読まれなくなる)。
stamp="$(ctx_state_stamp_file "$ctx")" || fail "ctx として使えない名前: $ctx"
turn_file="$(ctx_turn_file "$ctx")"
usage_file="$(ctx_usage_file "$ctx")"

# usage.json から transcript_path を読めるうちは ctx の取り違えを検出できる。
# 読めない窓(圧縮直後の不在・破損)では材料が無いので検査を課さない。
if [[ -r "$usage_file" ]]; then
  recorded="$(jq -r '.transcript_path // empty' "$usage_file" 2>/dev/null || true)"
  if [[ -n "$recorded" ]]; then
    [[ "$(claude_ctx_key "$recorded")" == "$ctx" ]] ||
      fail "usage.json の transcript_path が別の ctx を指している: $state"
  fi
fi

# 構造 NG の state を新鮮なまま残さない(残すと次の停止でナッジが出ず、
# 壊れた state のまま許容ターン数だけ沈黙する)。
# validator が無いときは構造検証を諦めて先へ進む(precompact-gate と同じ向き)。
# ここで FAIL にすると、直しようのない理由でスタンプが永久に打てなくなる。
validator="$(dirname -- "${BASH_SOURCE[0]}")/validate-state.sh"
if [[ -r "$validator" ]]; then
  if ! validator_output="$(bash "$validator" "$state" 2>&1)"; then
    rm -f "$stamp" 2>/dev/null || true
    fail "構造検証に通らなかった: $validator_output"
  fi
fi

turn="$(cat "$turn_file" 2>/dev/null || true)"
case "$turn" in "" | *[!0-9]*)
  rm -f "$stamp" 2>/dev/null || true
  fail "ターンカウンタが読めない: $turn_file"
  ;;
esac

# pct は鮮度の副条件。読めなくても stamp 自体は打つ
# (圧縮直後は usage.json が消えており、ここで諦めると鮮度情報ごと失う)。
# 古い usage.json の pct は焼かない。読み側は「現在 pct が stamp より低い」を圧縮とみなして
# 使用率次元を外すので、実際より高い値を焼くとその次元が永久に効かなくなる。
pct="$(jq -r '.pct // empty' "$usage_file" 2>/dev/null || true)"
pct="${pct%%.*}"
updated_at="$(jq -r '.updated_at // empty' "$usage_file" 2>/dev/null || true)"
case "$updated_at" in
"" | *[!0-9]*) pct="" ;;
*) (($(date +%s) - updated_at > $(claude_ctx_usage_stale_secs))) && pct="" ;;
esac

# 他の書き手(hook 群)と同じく dir の実体・所有者・mode を検査してから書く
umask 077
claude_ctx_cache_ensure "$ctx" || fail "ctx ディレクトリの検証に失敗した: $ctx_dir"

# 一時ファイルは noclobber で開く(残骸の symlink 越しに書かせない)
tmp="$ctx_dir/.state-stamp.tmp"
# cache dir はモデルが覗く場所なので、失敗経路で残骸を置き去りにしない
trap 'rm -f "$tmp" 2>/dev/null || true' EXIT
rm -f "$tmp" 2>/dev/null || true
(
  set -C
  claude_ctx_state_stamp_line "$turn" "$pct" >"$tmp"
) 2>/dev/null || fail "stamp を書けない: $stamp"
mv -f "$tmp" "$stamp" 2>/dev/null || fail "stamp を確定できない: $stamp"

echo "PASS"
exit 0
