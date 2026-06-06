#!/usr/bin/env bash
# resolve-git-target.sh — push/commit/merge ゲート hook が「判定すべき実対象 working
# dir」をコマンド文字列から導出する単一情報源。
#
# 背景: push 前ゲートは従来 hook プロセスの cwd(= dispatcher 型運用ではプライマリ
# repo)で `git branch --show-current` していたため、`cd <worktree> && git push` や
# `git -C <worktree> push` の実対象を解釈できず cross-repo / 別 worktree push を構造的に
# 誤判定していた(RCA: Knowledge/pushゲートフックがプライマリrepo結合でcross-repo-push誤判定.md)。
# このライブラリで対象 dir を解決し、各 hook は `git -C "$target" ...` で判定する。
#
# 解析は best-effort であり敵対防御ではない: 難読化(`g=git; $g push`・変数経由 dir・
# eval)は素通る。安全 hook の意図は「正規 push を素通しつつ保護を維持」であり、悪意ある
# 回避の遮断ではない。解決不能時は cwd フォールバック(= 既存挙動)で安全側に倒す。
#
# bash 3.2 互換: 連想配列(declare -A)・`grep -P`・`${var,,}` を使わない。正規表現は
# ERE のみ・`[[:space:]]` を使い `\s`/`\b` を避ける(BSD grep / bash 3.2 の `[[ =~ ]]`)。
#
# set -euo pipefail はトップに置かない(source 時に呼び出し元シェルの set 状態を汚染する)。
# 関数は呼び出し元が非 strict でも自衛(空ガード / 2>/dev/null)。strict 化は直接実行
# ガード内でのみ行う(resolve-repo-key.sh と同作法)。

# コマンドを `&&` `||` `;` `|` と改行でセグメント分割し、1行1セグメントで返す。
# クォート内の区切り文字までは考慮しない(best-effort)。区切りはまず全て改行へ畳んで
# から空セグメントを落とす。前後空白は呼び出し側 / git_subcommand_of_segment で扱う。
split_git_segments() {
  local cmd="${1:-}"
  # 多文字区切り(&& ||)を単一の改行へ。続いて単文字区切り(; | & と実改行)も改行へ。
  # `&` 単体(バックグラウンド)も分割点にする。`|&` は `&` → 改行で吸収される。
  cmd="${cmd//&&/$'\n'}"
  cmd="${cmd//||/$'\n'}"
  cmd="${cmd//;/$'\n'}"
  cmd="${cmd//|/$'\n'}"
  cmd="${cmd//&/$'\n'}"
  local line
  while IFS= read -r line; do
    # 前後空白を除去し、非空のみ返す。
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] && printf '%s\n' "$line"
  done <<<"$cmd"
}

# セグメントから git のサブコマンド(最初の非オプション語)を返す。
# `git` 自体・グローバルオプション(`-C <dir>` / `-c k=v` / `--git-dir <d>` /
# `--work-tree <d>` / `--namespace <n>` / `-p` 等)をスキップする。引数付きグローバル
# オプションは値も飛ばす。サブコマンドが無ければ空を返す。
# 用途: `push`/`merge`/`commit` の厳密一致判定。`merge-base`/`merge-tree` や
# `git log | grep push` のような無関係語の誤爆を防ぐ。
#
# quote-aware(2026-06): 判定に使う各トークンを `_strip_one_quote` で1段除去してから
# 比較する。これで `git "push"` / `"git" push` / `git "commit" --amend` のクォート付き
# 素通り(Knowledge/字句grep型hookはクォート付きフラグを取りこぼす の層 (b))を構造的に
# 塞ぐ。サブコマンド検出に依存する全 hook(protected-branch-push / no-verify / force-push /
# amend-pushed)へ呼出側無変更で波及する。戻り値の契約(サブコマンド名 or 空)は不変。
# 二重クォート(`"'push'"`)は1段のみ除去で best-effort(受容)。
git_subcommand_of_segment() {
  local seg="${1:-}"
  local -a words=()
  # 単語分割(クォートは考慮しない best-effort。トークン内のクォート文字は下で1段除去)。
  read -r -a words <<<"$seg"
  local n=${#words[@]}
  [[ $n -eq 0 ]] && return 0

  local i=0
  # 先頭の `git` を見つけるまで進める(`sudo git ...` 等の prefix を許容)。
  while [[ $i -lt $n ]]; do
    case "$(_strip_one_quote "${words[$i]}")" in
    git) i=$((i + 1)); break ;;
    *) i=$((i + 1)) ;;
    esac
  done
  [[ $i -ge $n ]] && return 0

  # グローバルオプションをスキップして最初のサブコマンドへ。
  while [[ $i -lt $n ]]; do
    local w
    w="$(_strip_one_quote "${words[$i]}")"
    case "$w" in
    # 値が別語の引数付きグローバルオプション(値も飛ばす)。
    # 値がクォートで空白を含む(`-c "k=v with space"`)場合 `read -r -a` がクォートを
    # 尊重せず空白分割するため、値が複数語に割れる。クォートが閉じるまで読み飛ばし
    # 続行し、`-c` 値の途中語(`Doe"`)をサブコマンドに取り違えない(M-1)。
    -C | -c | --git-dir | --work-tree | --namespace | --exec-path | --super-prefix)
      i=$((i + 1))
      i=$(_skip_option_value words "$n" "$i") ;;
    # glued `-C<path>`(空白なし)は値を内包する1語。`git_subcommand_of_segment` と
    # `_git_c_dir_of_segment` の glued 扱いを対称化する(M-2)。
    -C?*)
      i=$((i + 1)) ;;
    # `--opt=value` 形式は1語スキップ(-c= は git が受け付けない形なので扱わない)。
    --git-dir=* | --work-tree=* | --namespace=* | --exec-path=*)
      i=$((i + 1)) ;;
    # 値を取らないグローバルフラグ。
    -p | --paginate | -P | --no-pager | --bare | --no-replace-objects | \
      --literal-pathspecs | --no-optional-locks | --html-path | --man-path | --info-path)
      i=$((i + 1)) ;;
    # その他の `-` 始まりは未知グローバルオプションとみなしスキップ(安全側)。
    -*) i=$((i + 1)) ;;
    # 非オプション語 = サブコマンド。
    *) printf '%s' "$w"; return 0 ;;
    esac
  done
  return 0
}

# 引数付きグローバルオプションの値(words[start])を飛ばし、次の語の index を返す。
# 値がクォート(' か ")で開き、その語内で閉じていない場合、クォートが閉じる語まで
# 読み飛ばしを続ける(`read -r -a` の空白分割で値が複数語に割れた状態の復元)。
# bash 3.2 互換: 連想配列を使わず name ref 代わりに配列名を間接展開する。
_skip_option_value() {
  local _arr="$1" _n="$2" _i="$3"
  [[ $_i -ge $_n ]] && { printf '%s' "$_i"; return 0; }
  local first
  eval "first=\"\${${_arr}[$_i]}\""
  _i=$((_i + 1))
  # 値の先頭語がクォートを開いたまま閉じていなければ、閉じる語まで消費する。
  case "$first" in
  \"*)
    case "${first#\"}" in
    *\"*) : ;; # 同語内で閉じている
    *)
      while [[ $_i -lt $_n ]]; do
        local _w
        eval "_w=\"\${${_arr}[$_i]}\""
        _i=$((_i + 1))
        case "$_w" in *\"*) break ;; esac
      done ;;
    esac ;;
  \'*)
    case "${first#\'}" in
    *\'*) : ;;
    *)
      while [[ $_i -lt $_n ]]; do
        local _w
        eval "_w=\"\${${_arr}[$_i]}\""
        _i=$((_i + 1))
        case "$_w" in *\'*) break ;; esac
      done ;;
    esac ;;
  esac
  printf '%s' "$_i"
}

# クォート(' か ")を1段剥がす。`'/a/b'` → `/a/b`、`"/a/b"` → `/a/b`。
_strip_one_quote() {
  local s="${1:-}"
  case "$s" in
  \'*\') s="${s#\'}"; s="${s%\'}" ;;
  \"*\") s="${s#\"}"; s="${s%\"}" ;;
  esac
  printf '%s' "$s"
}

# あるセグメント内の `git -C <dir>` の dir を返す(クォート1段除去済み)。無ければ空。
_git_c_dir_of_segment() {
  local seg="${1:-}"
  local -a words=()
  read -r -a words <<<"$seg"
  local n=${#words[@]}
  local i=0
  # `-C` フラグも quote-aware に探す(`git "-C" /x push` 対応)。git_subcommand_of_segment と
  # 対称に各トークンを _strip_one_quote してから比較する。dir 値の strip は既存どおり維持。
  while [[ $i -lt $n ]]; do
    local w
    w="$(_strip_one_quote "${words[$i]}")"
    case "$w" in
    -C)
      if [[ $((i + 1)) -lt $n ]]; then
        _strip_one_quote "${words[$((i + 1))]}"
      fi
      return 0
      ;;
    # glued `-C<path>`(空白なし)。rest 非空なら即 dir、空(`-C`単独)は上の枝で次語(M-2)。
    -C?*)
      printf '%s' "${w#-C}"
      return 0
      ;;
    esac
    i=$((i + 1))
  done
  return 0
}

# セグメント先頭が `cd <dir>` のとき、その dir を返す(クォート1段除去済み)。無ければ空。
# `cd -- <dir>` / `cd -L <dir>` / `cd -P <dir>` の先頭フラグは飛ばし最初の非フラグ語を dir
# とする(dispatcher で `cd -- <wt> && git push` を使う場合の cwd 誤判定対策)。
_leading_cd_dir_of_segment() {
  local seg="${1:-}"
  local -a words=()
  read -r -a words <<<"$seg"
  local n=${#words[@]}
  [[ $n -lt 2 ]] && return 0
  [[ "${words[0]}" != "cd" ]] && return 0
  local i=1
  while [[ $i -lt $n ]]; do
    case "$(_strip_one_quote "${words[$i]}")" in
    --) i=$((i + 1)); break ;;
    -L | -P) i=$((i + 1)) ;;
    *) break ;;
    esac
  done
  [[ $i -lt $n ]] && _strip_one_quote "${words[$i]}"
  return 0
}

# セグメント内に指定オプションがあるか quote-aware に判定する(2026-06)。
# 各トークンを `_strip_one_quote` で1段除去してから比較するため、`git push "--force"` /
# `git commit '--amend'` のクォート付き素通り(Knowledge/字句grep型hookはクォート付き
# フラグを取りこぼす の層 (a))を構造的に塞ぐ。grep -E の語境界クラス拡張より頑健。
#
# 使い方: segment_has_option <seg> <long-opt> [short-char]
#   long-opt 完全一致(例 --force / --no-verify / --amend)または `--opt=値`、もしくは
#   short-char を含む短縮束(例 -f / -uf / -fu / -anm)があれば 0、無ければ 1。
# 複数の long を見たいときは OR で反復呼出する(案A: API を単純に保つ。force の3枝など)。
# long を見ないなら "" を渡す(short のみ判定)。
#
# 既知の限界(受容): `read -r -a` はクォートを尊重せず空白分割するため、メッセージ本文の
# `--amend` 様トークン(`git commit -m "fix --amend bug"`)を拾い誤ブロックしうる。これは
# 既存の grep 方式と同じ受容済み偽陽性であり退行ではない。
segment_has_option() {
  local seg="${1:-}" long="${2:-}" shortc="${3:-}"
  local -a words=()
  read -r -a words <<<"$seg"
  [[ ${#words[@]} -eq 0 ]] && return 1
  local raw w
  for raw in "${words[@]}"; do
    w="$(_strip_one_quote "$raw")"
    if [[ -n "$long" ]]; then
      [[ "$w" == "$long" ]] && return 0
      [[ "$w" == "$long="* ]] && return 0
    fi
    if [[ -n "$shortc" ]]; then
      case "$w" in
      --*) : ;;
      -*"$shortc"*) return 0 ;;
      esac
    fi
  done
  return 1
}

# セグメントを quote-aware に正規化したトークン列(空白1個区切り)を返す(2026-06)。
# 各トークンを `_strip_one_quote` で1段除去して連結する。`gh pr "merge"` → `gh pr merge`
# のように、多語サブコマンド(gh pr merge / git worktree add)を検出する hook が、既存の
# 練られた ERE(BORDER/FLAGS/ENV)を温存したまま正規化後文字列にマッチできるようにする
# (トークン照合への作り替えは差分・退行リスクが大きいので grep -E 継続を選択)。
normalized_words_of_segment() {
  local seg="${1:-}"
  local -a words=()
  read -r -a words <<<"$seg"
  [[ ${#words[@]} -eq 0 ]] && return 0
  local out="" raw w
  for raw in "${words[@]}"; do
    w="$(_strip_one_quote "$raw")"
    out="${out:+$out }$w"
  done
  printf '%s' "$out"
}

# 相対パスを base(cwd)基準で物理絶対パス化。解決不能なら空を返す。
_abs_dir() {
  local dir="${1:-}" base="${2:-}"
  [[ -z "$dir" ]] && return 0
  case "$dir" in
  /*) (cd "$dir" 2>/dev/null && pwd -P) || true ;;
  "~"/* | "~") (cd "${dir/#\~/$HOME}" 2>/dev/null && pwd -P) || true ;;
  *) (cd "$base" 2>/dev/null && cd "$dir" 2>/dev/null && pwd -P) || true ;;
  esac
}

# push 実対象 working dir を導出する。
# 規則(優先順): 対象サブコマンド(push/merge/commit)を含むセグメント内の `git -C <dir>`
#   > コマンド全体で最初に現れる先頭 `cd <dir>` > <cwd>。
# 相対は cwd 基準で解決。解決不能(存在しない dir 等)は <cwd> フォールバック(安全側)。
resolve_git_target_dir() {
  local cmd="${1:-}" cwd="${2:-$PWD}"
  local target=""

  local seg sub cdir
  # 1) 対象サブコマンドを含むセグメントの `git -C <dir>` を最優先。
  while IFS= read -r seg; do
    [[ -z "$seg" ]] && continue
    sub="$(git_subcommand_of_segment "$seg")"
    case "$sub" in
    push | merge | commit)
      cdir="$(_git_c_dir_of_segment "$seg")"
      if [[ -n "$cdir" ]]; then
        target="$(_abs_dir "$cdir" "$cwd")"
        [[ -n "$target" ]] && { printf '%s' "$target"; return 0; }
      fi
      ;;
    esac
  done < <(split_git_segments "$cmd")

  # 2) `git -C` 無しなら、セグメント順に `cd` を畳んだ仮想 cwd を更新し、
  #    push/merge/commit 到達時点の cwd を採用する。`cd a && cd b && git push` で
  #    最初の `cd a` ではなく実際の到達先 b を返す(連鎖 cd の取り違え防止)。
  local current="$cwd"
  while IFS= read -r seg; do
    [[ -z "$seg" ]] && continue
    cdir="$(_leading_cd_dir_of_segment "$seg")"
    if [[ -n "$cdir" ]]; then
      target="$(_abs_dir "$cdir" "$current")"
      [[ -n "$target" ]] && current="$target"
      continue
    fi
    case "$(git_subcommand_of_segment "$seg")" in
    push | merge | commit)
      printf '%s' "$current"
      return 0
      ;;
    esac
  done < <(split_git_segments "$cmd")

  # 3) フォールバック = cd を畳んだ最終 cwd(git action 無しなら cwd のまま)。
  printf '%s' "$current"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  set -euo pipefail
  resolve_git_target_dir "${1:-}" "${2:-$PWD}"
  printf '\n'
fi
