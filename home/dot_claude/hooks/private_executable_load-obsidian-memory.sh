#!/usr/bin/env bash
# load-obsidian-memory.sh — SessionStart hook (startup|resume|clear)
#
# Obsidian Vault(~/obsidian/brain)の Tier0 を additionalContext として注入する。
# Tier0 = Preferences/* 全文 + Knowledge/mistakes.md 末尾 + 自動生成 MOC(索引)。
# Vault 本体はローカル限定・固定パス・どのリポにも入らない。Tier1 本文は注入せず、
# Claude が MOC を見て Grep/Glob + [[wikilink]] でオンデマンドに読む。
#
# 安全側設計: 注入の失敗でセッションを止めない。jq 不在 / vault 不在(業務 PC 等)/
# 想定外のエラーはすべて exit 0 で素通り(コンテキスト注入は best-effort)。
set -euo pipefail

command -v jq &>/dev/null || exit 0

# SessionStart 入力 JSON(cwd/source)は使わないので読み捨てる。
cat >/dev/null || true

VAULT="$HOME/obsidian/brain" # 全 PC 共通の固定パス
[[ -d "$VAULT" ]] || exit 0  # 未存在(業務 PC 等)→ 無音で素通り

MOC_MAX=800  # MOC 行数上限。Tier0 を実質定数に丸める
MIST_MAX=200 # mistakes.md 末尾行数

# --- MOC 索引の自動生成(.index/MOC.md) ---
# 注意: `... | head -n N` は head の早期終了で producer が SIGPIPE を受け、
# `set -o pipefail` 下では script 全体が落ちうる。これを避けるため生成側を
# awk で行数制限し、head にパイプしない(best-effort を壊さない)。
INDEX_DIR="$VAULT/.index"
MOC="$INDEX_DIR/MOC.md"
mkdir -p "$INDEX_DIR"
{
  echo "# MOC(自動生成 / $(date +%F)) — Tier1 本文は Grep/Glob + [[wikilink]] で必要分だけ読む"
  # 除外: mistakes.md(Tier0 で全文ロード済み)/ _README.md(フォルダ説明の足場でノイズ)
  find "$VAULT/Knowledge" "$VAULT/Decisions" "$VAULT/Projects" -name '*.md' ! -name 'mistakes.md' ! -name '_README.md' -type f 2>/dev/null |
    sort | while IFS= read -r f; do
    rel="${f#"$VAULT"/}"
    # title = 本文1行目見出し → 無ければ空 / meta = frontmatter tags+project を1行圧縮
    title="$(awk '/^# /{sub(/^# /,"");print;exit}' "$f")"
    meta="$(awk -F': ' '/^tags:|^project:/{printf "%s ",$2}' "$f")"
    printf -- "- [[%s]] %s%s\n" "$rel" "${title:+$title }" "${meta:+($meta)}"
  done
} | awk -v max="$MOC_MAX" 'NR<=max' >"$MOC" # 生成側を制限(head 不使用で SIGPIPE 回避)

# --- Tier0 を additionalContext に注入 ---
BODY="$(
  echo "# 永続記憶(外部脳)Tier0 — 自動ロード。読込手順は hook が代行済み"
  echo "## Preferences(好み・作業スタイル)"
  # _README.md は除外: フォルダ説明の足場であり毎セッション注入する価値がない
  find "$VAULT/Preferences" -maxdepth 1 -name '*.md' ! -name '_README.md' -type f -exec cat {} + 2>/dev/null || true
  echo
  echo "## 行動ルール / AI のミス記録(mistakes.md)"
  tail -n "$MIST_MAX" "$VAULT/Knowledge/mistakes.md" 2>/dev/null || true
  echo
  echo "## 索引(MOC) — 本文は未ロード。関連ノートは Grep/Glob + [[wikilink]] で読む"
  cat "$MOC" 2>/dev/null || true
)"

jq -n --arg body "$BODY" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $body
  }
}' || exit 0

exit 0
