#!/usr/bin/env bash
# create-worktree.sh — WorktreeCreate hook(Stage 1: flat リダイレクトのみ)
#
# Claude Code ネイティブ worktree(--worktree / delegate の isolation:"worktree")の
# 配置先を、既定の <repo>/.claude/worktrees/agent-* から flat 配置
# ~/worktrees/<host>/<owner>/<repo>/<branch> へリダイレクトする。配置規約の穴
# (作業ツリー直下に worktree が生える)を塞ぐ。依存物供給(copy / mise trust /
# pnpm store)は Stage 2 に分離しスコープ外。
#
# 契約(claude 2.1.156 / code.claude.com docs で一次確認):
#   入力 stdin JSON: cwd / worktree_path(既定先) / branch_name / base_branch 等。
#   出力: stdout に絶対パスを1行 + exit 0 → その文字列が新 worktree の配置先になる。
#   責務境界: hook は「配置先パスを返すだけ」。git worktree add は Claude Code 本体が
#   実行する(= default git behavior の "配置先選択" を replace。add 自体は replace
#   しない)。だから wt.sh をそのまま呼べず、パス導出の純関数だけを共有する。
#
# パス導出は dotfiles 側の単一情報源 lib を絶対パスで source する(決定 a1)。dotfiles は
# 基盤リポで常在前提(グローバル CLAUDE.md も wt.sh を dotfiles 絶対パスで参照している)。
#
# 安全側設計: 導出に失敗(lib 不在 / jq 不在 / origin 無し / git 外 / パース不能)した場合は
# 既定 worktree_path をそのまま echo + exit 0(= 従来挙動へフォールバック)。作成中止
# (非ゼロ exit)は使わない。同一ブランチ衝突・空 branch_name は git に委ねて失敗させる
# (hook では冪等再利用しない = wt.sh 経路のみ)。
#
# bash 3.2 互換(macOS 既定)。
set -euo pipefail

WORKTREE_LIB="$HOME/ghq/github.com/Hirayama61/dotfiles/bin/lib/resolve-worktree-path.sh"

# フォールバック変数は emit_fallback が参照するので最初に初期化する(set -u 安全)。
# fallback_path = 既定 worktree_path(導出失敗時にそのまま返す)。未取得段階で
# emit_fallback が呼ばれたら空のまま = 無出力 + exit 0(本体が既定パスで作る)。
fallback_path=""
branch_name=""
cwd=""

emit_fallback() {
  # 安全フォールバック: worktree_path が取れていればそれを echo、無ければ無出力で exit 0。
  # WorktreeCreate hook の非ゼロ終了は「作成中止」を意味するため、degrade は必ず exit 0。
  [[ -n "$fallback_path" ]] && printf '%s\n' "$fallback_path"
  exit 0
}

input="$(cat)"

# jq 不在は degrade(exit 0)。
command -v jq >/dev/null 2>&1 || emit_fallback

# worktree_path / branch_name / cwd を jq 1 回で抽出する(F-010: 3 回 → 1 回)。
# set -euo pipefail 下では不正 JSON で jq が非ゼロ終了すると emit_fallback 到達前に死に
# 「作成中止」になる。抽出を if でガードし parse error 等を degrade(exit 0)へ流す
# (本命の契約バグ修正)。
# 出力は 1 フィールド 1 行に固定し、各行を read で順に受ける。@tsv のタブ区切り +
# IFS=tab read だと、tab は IFS の空白クラス扱いで先頭の空フィールド(worktree_path 欠落)が
# 詰められ branch_name が worktree_path 位置にずれる。行区切り + 行ごと read なら空フィールドを
# 保てる。値内改行は jq -r の \n エスケープ前提で 1 行 1 値が崩れない。
extracted=""
if ! extracted="$(printf '%s' "$input" \
  | jq -r '.worktree_path // "", .branch_name // "", .cwd // ""' 2>/dev/null)"; then
  emit_fallback
fi
# 末尾行に改行が無い / 抽出が空のとき最後の read が EOF で非ゼロを返す。set -e 下で
# group が落ちないよう || true で吸収する(read 済みの値は失われない)。
{
  IFS= read -r fallback_path
  IFS= read -r branch_name
  IFS= read -r cwd
} <<EOF || true
$extracted
EOF

[[ -f "$WORKTREE_LIB" ]] || emit_fallback
[[ -n "$branch_name" ]] || emit_fallback
[[ -n "$cwd" && -d "$cwd" ]] || emit_fallback

# lib が構文壊れだと `. "$WORKTREE_LIB"` の parse error は if ! でも捕まえられず set -e と
# 無関係に shell ごと exit 2 で落ち「作成中止」になる。source 前に bash -n で構文検証し、
# 壊れていれば degrade(exit 0)へ回す(parse error を捕捉可能な事前チェックに変換する)。
bash -n "$WORKTREE_LIB" 2>/dev/null || emit_fallback
# shellcheck source=/dev/null
. "$WORKTREE_LIB" || emit_fallback

target="$(resolve_worktree_path "$branch_name" "$cwd")" || emit_fallback
[[ -n "$target" ]] || emit_fallback

# 親 dir 作成は本体の git worktree add がやる想定だが、未確定なので安全側で先に作る
# (無害・冪等)。wt.sh も同様に親 dir を mkdir -p している。
mkdir -p "$(dirname "$target")" 2>/dev/null || true

printf '%s\n' "$target"
