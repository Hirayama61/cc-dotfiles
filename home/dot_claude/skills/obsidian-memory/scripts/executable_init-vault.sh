#!/usr/bin/env bash
# init-vault.sh — Obsidian 永続記憶 vault(~/obsidian/brain)の空構造を冪等生成する。
#
# 冪等・既存ノート不可侵: フォルダ作成は mkdir -p、ファイルは「無ければ作る」のみ。
# 既存の中身は一切上書きしない。vault は git 管理しない(ローカルで育てる)。
set -euo pipefail

VAULT="$HOME/obsidian/brain"

mkdir -p "$VAULT"/{Knowledge,Decisions,Projects,Preferences,.index}

MISTAKES="$VAULT/Knowledge/mistakes.md"
[[ -e "$MISTAKES" ]] || : >"$MISTAKES"

write_readme_if_absent() {
  local path="$1"
  shift
  [[ -e "$path" ]] && return 0
  printf '%s\n' "$@" >"$path"
}

write_readme_if_absent "$VAULT/Knowledge/_README.md" \
  "# Knowledge — 技術知見・解決したバグ・新発見" \
  "" \
  "バグ/問題の解決(原因と解決策をペアで)、ライブラリ・API・ツールの新発見、" \
  "環境構築でハマって解決したこと、「次回知っておきたかった」ことを記録する。" \
  "命名: topic-subtopic.md(例 nextjs-auth-cookie.md)。" \
  "" \
  "mistakes.md は AI のミス記録(SessionStart hook が末尾を自動ロードする)。"

write_readme_if_absent "$VAULT/Decisions/_README.md" \
  "# Decisions — 判断・方針の記録" \
  "" \
  "複数選択肢から1つを選んだ判断(A vs B、なぜ A か)、設計・方針の決定を記録する。" \
  "命名: YYYY-MM-DD-topic.md(例 2026-05-16-database-choice.md)。"

write_readme_if_absent "$VAULT/Projects/_README.md" \
  "# Projects — 進行中プロジェクトの状態" \
  "" \
  "プロジェクトの状態・バージョン・概要が変わったら記録する。" \
  "命名: project-name.md。"

write_readme_if_absent "$VAULT/Preferences/_README.md" \
  "# Preferences — 好み・作業スタイル" \
  "" \
  "ユーザーの好み・作業スタイルを新たに発見したら記録する(SessionStart hook が" \
  "全文を自動ロードする)。命名: category.md(例 coding-style.md)。" \
  "" \
  "最初に profile.md に自己紹介・前提・よく使うスタックを書いておくと良い。"

cat <<EOF
Obsidian 永続記憶 vault を初期化しました: $VAULT

作成したフォルダ:
  Knowledge/    技術知見・解決したバグ・新発見(+ mistakes.md = AI のミス記録)
  Decisions/    判断・方針の記録
  Projects/     進行中プロジェクトの状態
  Preferences/  好み・作業スタイル
  .index/       MOC(索引)自動生成先(SessionStart hook が更新)

最初に Preferences/profile.md に自己紹介・前提・よく使うスタックを書いておくと、
以後のセッションで Tier0 として毎回自動ロードされます。
Obsidian で開く時はこの $VAULT フォルダを vault として追加してください。
EOF
