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
# 見つからなければ空(= 作業ツリー無し)を返す。read-only。
resolve_worktree() {
  local repo="$1" path=""
  # repo を grep の ERE に渡す前にメタ文字をエスケープ。文字クラスは先頭 ] が文字どおりの
  # ']'、末尾 \\ が '\'(現状の repo キーは英数とハイフンのみだが防御的に)。
  local esc
  esc="$(printf '%s' "$repo" | sed -E 's/[][(){}.^$*+?|\\]/\\&/g')"
  # 同名 basename が別 owner 配下に複数あると head -1 が ghq 列挙順で先頭を黙って選ぶ
  # (現状の repo は衝突なし。衝突時は呼び出し側で要確認)。
  path="$(ghq list --full-path 2>/dev/null | grep -E "/${esc}\$" | head -1 || true)"
  printf '%s' "$path"
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

while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  if [[ "$key" == "_shared" ]]; then
    # _shared は常に「横断・メタ」ラベル付きで末尾。作業ツリーは持たない。
    without_tree+="${key}"$'\t'"(no-worktree)"$'\n'
    continue
  fi
  wt="$(resolve_worktree "$key")"
  if [[ -n "$wt" ]]; then
    with_tree+="${key}"$'\t'"${wt}"$'\n'
  else
    without_tree+="${key}"$'\t'"(no-worktree)"$'\n'
  fi
done <<<"$all_keys"

# 作業ツリーありを先に、無し(_shared・論理プロジェクト)を末尾に出す。
printf '%s' "$with_tree"
printf '%s' "$without_tree"
