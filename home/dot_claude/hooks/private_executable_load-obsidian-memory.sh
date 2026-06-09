#!/usr/bin/env bash
# load-obsidian-memory.sh — SessionStart hook (startup|resume|clear)
#
# Obsidian Vault(~/obsidian/brain)の Tier0 を additionalContext として注入する。
# Tier0 = Preferences/* 全文 + 現在 repo の「生きたガイド」(ルートガイド)。
# Vault 本体はローカル限定・固定パス・どのリポにも入らない。詳細サブノートは注入せず、
# Claude がガイド内の [[wikilink]] / Grep / Glob でオンデマンドに読む。
#
# 経緯: 旧版は自動生成 MOC(Knowledge/Decisions/Projects/Mistakes を1行ずつ列挙した索引)を
# 注入していたが、ノート増加に比例して索引が肥大し Tier0 が膨らんだ。これを廃し、人手で
# 育てる repo 単位のルートガイド1枚に置き換える。注入量はガイドのサイズで有界化され、
# 個々のサブ知見はガイドからのリンクでオンデマンドに辿る(常時注入しない)。
#
# 安全側設計: 注入の失敗でセッションを止めない。jq 不在 / vault 不在(業務 PC 等)/
# 想定外のエラーはすべて exit 0 で素通り(コンテキスト注入は best-effort)。
set -euo pipefail

command -v jq &>/dev/null || exit 0

# cwd から現在 repo の論理キーを導出し、注入するルートガイドを現在 repo に対応づける。
# 空(repo 外 / vault 直編集中)ならガイドは注入せず Preferences のみ(REPO_KEY="")。
input="$(cat)" || true
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
REPO_KEY=""
RESOLVER="$HOME/.claude/hooks/lib/resolve-repo-key.sh"
if [[ -n "$cwd" && -x "$RESOLVER" ]]; then
  REPO_KEY="$("$RESOLVER" "$cwd" 2>/dev/null || true)"
fi

VAULT="$HOME/obsidian/brain" # 全 PC 共通の固定パス
[[ -d "$VAULT" ]] || exit 0  # 未存在(業務 PC 等)→ 無音で素通り

# ルートガイドのパスを決定的に組み立てる($VAULT/Guides/<repo>/<repo>-ガイド.md)。
# REPO_KEY が非空かつ実在するときのみ注入。無ければ lazy(注入なし)で Preferences のみ。
# ルートガイドは「実ファイル」に限定する(find -type f は symlink=-type l を除外)。
# Guides/<repo>/ に貼られた symlink 経由で vault 外(~/.ssh 等)を注入させないため。
# 日本語名は NFC 前提(guide-capture が NFC で生成)。NFD でディスクに在るとマッチせず
# 無音 skip する既知の制約。head を使わず pipefail 下の SIGPIPE を避ける。
GUIDE=""
if [[ -n "$REPO_KEY" ]]; then
  GUIDE="$(find "$VAULT/Guides/$REPO_KEY" -maxdepth 1 -type f -name "$REPO_KEY-ガイド.md" 2>/dev/null || true)"
  GUIDE="${GUIDE%%$'\n'*}"
fi

# --- Tier0 を additionalContext に注入 ---
BODY="$(
  echo "# 永続記憶(外部脳)Tier0 — 自動ロード。読込手順は hook が代行済み"
  echo "## Preferences(好み・作業スタイル)"
  # _README.md は除外: フォルダ説明の足場であり毎セッション注入する価値がない
  find "$VAULT/Preferences" -maxdepth 1 -name '*.md' ! -name '_README.md' -type f -exec cat {} + 2>/dev/null || true
  if [[ -n "$GUIDE" ]]; then
    echo
    echo "## 生きたガイド($REPO_KEY)— 最新の運用知。詳細サブは [[link]]/Grep でオンデマンド"
    # 注入量の安全上限。ルートを小さく保つ規律が破れても注入を有界にする。
    head -c 20000 "$GUIDE" 2>/dev/null || true
  fi
)"

jq -n --arg body "$BODY" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $body
  }
}' || exit 0

exit 0
