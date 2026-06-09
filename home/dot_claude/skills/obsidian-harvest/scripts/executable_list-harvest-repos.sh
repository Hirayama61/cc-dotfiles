#!/usr/bin/env bash
# list-harvest-repos.sh — obsidian-harvest の「外部脳に登録のある repo」列挙(read-only)。
#
# obsidian-harvest 手順1(repo 列挙 → 1つ選択)の入力を 1 コマンドで供給する。
# 毎回の手探り(どの repo に Decisions/Mistakes/project frontmatter があるか)を潰す。
#
# 列挙ロジック(SKILL.md 手順1。OR 合算 → 一意化):
#   1. Decisions/<repo>/  のサブディレクトリ名
#   2. Mistakes/<repo>/   のサブディレクトリ名
#   3. Knowledge/ + Projects/ の `project:` frontmatter 値
# `_shared`(横断・メタ)と論理プロジェクト(git repo 無し)は末尾へ寄せ、作業ツリー
# 解決に失敗したものは "(no-worktree)" を付す(採掘シグナルが減ることを呼び出し側に示す)。
#
# 出力(stdout)= 1 行 1 repo: "<repo>\t<作業ツリーパス or (no-worktree)>"(タブ区切り)。
# AskUserQuestion 用の「作業ツリー有/無」ラベルにそのまま使える。
# 同名 basename が複数 owner 配下に衝突する repo は head -1 の実在パスを右列に保ったまま、
# 第3列 "\t(ambiguous:N)" と stderr 警告で曖昧性を示す(右列は常に valid path = 下流の
# cd 先 / AskUserQuestion ラベル契約を壊さない。F-003)。
#
# read-only 厳守: Vault も ghq も**一切書かない**。env OBSIDIAN_VAULT で vault パス上書き可。

set -euo pipefail

VAULT="${OBSIDIAN_VAULT:-$HOME/obsidian/brain}"

if [[ ! -d "$VAULT" ]]; then
  echo "list-harvest-repos: vault not found: $VAULT" >&2
  exit 1
fi

# --- 1+2. Decisions/ と Mistakes/ のサブディレクトリ名 ----------------------------
# _README.md 等のファイルは拾わない(-d でディレクトリのみ)。`_shared` は後で末尾寄せ。
collect_subdirs() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  local d
  for d in "$dir"/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"; printf '%s\n' "${d##*/}"
  done
}

# --- 3. Knowledge/ + Projects/ の project: frontmatter 値 --------------------------
collect_project_frontmatter() {
  local d
  for d in "$VAULT/Knowledge" "$VAULT/Projects"; do
    [[ -d "$d" ]] || continue
    # frontmatter の `project:` 行のみ拾い、値だけ抽出(quote / 空白を除去)。
    # --include=*.md は env で別ツリーを指定された際の全走査暴走を抑止。|| true は
    # no-match(正常系)で pipefail 下に関数が落ちるのを防ぐ。
    { grep -rhoE --include='*.md' '^project:[[:space:]]*.+' "$d" 2>/dev/null || true; } \
      | sed -E 's/^project:[[:space:]]*//; s/^["'\'']//; s/["'\'']$//' \
      | sed -E 's/[[:space:]]+$//'
  done
}

# repo キー → 作業ツリーパス逆解決(resolve-repo-key.sh の逆。SKILL.md 手順1)。
# ghq の全 repo フルパスから末尾セグメント一致を引く。github.com/ も local/ も拾える。
# stdout = "<head -1 の実在パス>\t<衝突数>"(見つからなければ空)。path にタブは入らないので
# 呼び出し側は read で 2 値に分解できる。衝突数を別フィールドで返すのは、command 置換が
# subshell で走り global 変数を親へ伝播できないため(F-003。右列の path は常に valid に保つ)。
resolve_worktree() {
  local repo="$1" all_paths="$2" path=""
  # repo を grep の ERE に渡す前にメタ文字をエスケープ。文字クラスは先頭 ] が文字どおりの
  # ']'、末尾 \\ が '\'。repo キーは英数・ハイフン・アンダースコア・ドット(末尾の文字種
  # フィルタ ^[A-Za-z0-9._-]+$ と一致。ドットは next.js / *.github.io 等の repo 名のため許容)。
  local esc
  esc="$(printf '%s' "$repo" | sed -E 's/[][(){}.^$*+?|\\]/\\&/g')"
  # 同名 basename が別 owner 配下に複数あるとどれが正か機械的に決められない。先頭採用は
  # 維持しつつ衝突数を返し、下流(AskUserQuestion / cd 先)が「先頭採用パスは確実でない」と
  # 解釈できるようにする。右列(path)は常に valid path に保ち、曖昧シグナルは衝突数として
  # 呼び出し側へ渡す(右列を作業ツリーパスとして使う出力契約を壊さない)。
  # ghq list は呼び出し側で 1回だけ取得した結果を all_paths として渡す(再実行を避ける)。
  local matches count
  matches="$(printf '%s\n' "$all_paths" | grep -E "/${esc}\$" || true)"
  [[ -n "$matches" ]] || return 0
  count="$(printf '%s\n' "$matches" | grep -c '')"
  path="$(printf '%s\n' "$matches" | head -1)"
  printf '%s\t%s' "$path" "$count"
}

# --- 合算 → 一意化。`_shared`・論理プロジェクトを末尾へ --------------------------
# grep を || true で囲むのは pipefail 下で no-match(空集合=初回/空 vault の正常系)に
# スクリプト全体が落ちないため。末尾の文字種フィルタは、本文混入や下流プロンプトへの
# 注入素地になりうる不正キー(空白・引用符・指示文等)を落とす。
all_keys="$(
  {
    collect_subdirs "$VAULT/Decisions"
    collect_subdirs "$VAULT/Mistakes"
    collect_project_frontmatter
  } | sed -E 's/[[:space:]]+$//' \
    | { grep -vE '^$' || true; } \
    | { grep -E '^[A-Za-z0-9._-]+$' || true; } \
    | sort -u
)"

# 通常 repo(作業ツリーあり)と、作業ツリー無し(_shared / 論理プロジェクト / 未 clone)を分ける。
with_tree=""
without_tree=""

# ghq の全 repo フルパスはループ前に1回だけ取得し、各 repo の解決へ使い回す
# (repo ごとに ghq を再起動しない。多数 repo 時の無駄なサブプロセスを避ける)。
ghq_paths="$(ghq list --full-path 2>/dev/null || true)"

while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  if [[ "$key" == "_shared" ]]; then
    # _shared は常に「横断・メタ」ラベル付きで末尾。作業ツリーは持たない。
    without_tree+="${key}"$'\t'"(no-worktree)"$'\n'
    continue
  fi
  IFS=$'\t' read -r wt count <<<"$(resolve_worktree "$key" "$ghq_paths")"
  if [[ -n "$wt" ]]; then
    if [[ "${count:-0}" -ge 2 ]]; then
      with_tree+="${key}"$'\t'"${wt}"$'\t'"(ambiguous:${count})"$'\n'
      echo "list-harvest-repos: warn: '${key}' は同名 repo が ${count} 件衝突。先頭採用 = ${wt}(要確認)" >&2
    else
      with_tree+="${key}"$'\t'"${wt}"$'\n'
    fi
  else
    without_tree+="${key}"$'\t'"(no-worktree)"$'\n'
  fi
done <<<"$all_keys"

# 作業ツリーありを先に、無し(_shared・論理プロジェクト)を末尾に出す。
printf '%s' "$with_tree"
printf '%s' "$without_tree"
