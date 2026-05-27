#!/usr/bin/env bash
# init-vault.sh — Obsidian 永続記憶 vault(~/obsidian/brain)の空構造を冪等生成する。
#
# 冪等・既存ノート不可侵: フォルダ作成は mkdir -p、ファイルは「無ければ作る」のみ。
# 既存の中身は一切上書きしない。vault は git 管理しない(ローカルで育てる)。
#
# taxonomy(案A): repo 固有 type は <type>/<repo>/ サブへ、横断・メタは <type>/_shared/ へ。
# repo サブディレクトリは書込時に mkdir -p で生やす(init で全 repo 分を先掘りしない=
# 空ディレクトリ量産を避ける)。
set -euo pipefail

VAULT="$HOME/obsidian/brain"

mkdir -p "$VAULT"/{Knowledge,Decisions,Mistakes,Projects,Preferences,.index}

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
  "共有・flat 維持(repo 別サブは作らない。横断の再利用資産レイヤー)。" \
  "命名: 日本語トピック.md(例 macOSのbashに連想配列が無い.md)。"

write_readme_if_absent "$VAULT/Decisions/_README.md" \
  "# Decisions — 判断・方針の記録" \
  "" \
  "複数選択肢から1つを選んだ判断(A vs B、なぜ A か)、設計・方針の決定を記録する。" \
  "repo 固有は Decisions/<repo>/、横断・メタ判断は Decisions/_shared/(書込時に mkdir)。" \
  "命名: YYYY-MM-DD-日本語トピック.md(例 2026-05-23-Obsidian外部脳アーキテクチャ.md)。"

write_readme_if_absent "$VAULT/Mistakes/_README.md" \
  "# Mistakes — ミスの観測ログ(1ミス1ファイル)" \
  "" \
  "AI のミスを観測ログとして溜める場所(防止ルールの実装先ではない)。溜めたログから" \
  "人間/レビュー工程が CLAUDE.md / hook の防止ルールへ昇華する材料にする。" \
  "1回目から軽量に記録してよい。Tier0 への毎セッション自動注入はしない(MOC 経由で参照)。" \
  "repo 固有は Mistakes/<repo>/、横断は Mistakes/_shared/(書込時に mkdir)。" \
  "命名: YYYY-MM-DD-日本語トピック.md(並列衝突時は YYYY-MM-DD-HHMMSS-... で時刻付与)。"

write_readme_if_absent "$VAULT/Projects/_README.md" \
  "# Projects — 進行中プロジェクトの状態" \
  "" \
  "プロジェクトの状態・バージョン・概要が変わったら記録する(1 repo 1ファイル)。" \
  "命名: プロジェクト名.md(repo 名に合わせ英語可。例 personal-staff.md)。"

write_readme_if_absent "$VAULT/Preferences/_README.md" \
  "# Preferences — 好み・作業スタイル" \
  "" \
  "ユーザーの好み・作業スタイルを新たに発見したら記録する(SessionStart hook が" \
  "全文を自動ロードする)。共有・flat 維持。命名: 日本語カテゴリ.md(例 コーディングスタイル.md)。" \
  "" \
  "最初に profile.md に自己紹介・前提・よく使うスタックを書いておくと良い。"

cat <<EOF
Obsidian 永続記憶 vault を初期化しました: $VAULT

作成したフォルダ:
  Knowledge/    技術知見・解決したバグ・新発見(共有・flat)
  Decisions/    判断・方針の記録(repo 固有は <repo>/、横断は _shared/)
  Mistakes/     ミスの観測ログ(repo 固有は <repo>/、横断は _shared/)
  Projects/     進行中プロジェクトの状態(1 repo 1ファイル)
  Preferences/  好み・作業スタイル(共有・flat)
  .index/       MOC(索引)自動生成先(SessionStart hook が更新)

<type>/<repo>/ と <type>/_shared/ のサブディレクトリは書込時に mkdir -p で生やします
(init では先掘りしません = 空ディレクトリを量産しない)。

最初に Preferences/profile.md に自己紹介・前提・よく使うスタックを書いておくと、
以後のセッションで Tier0 として毎回自動ロードされます。
Obsidian で開く時はこの $VAULT フォルダを vault として追加してください。
EOF
