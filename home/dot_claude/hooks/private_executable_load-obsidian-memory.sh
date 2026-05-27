#!/usr/bin/env bash
# load-obsidian-memory.sh — SessionStart hook (startup|resume|clear)
#
# Obsidian Vault(~/obsidian/brain)の Tier0 を additionalContext として注入する。
# Tier0 = Preferences/* 全文 + 自動生成 MOC(索引)。
# Vault 本体はローカル限定・固定パス・どのリポにも入らない。Tier1 本文は注入せず、
# Claude が MOC を見て Grep/Glob + [[wikilink]] でオンデマンドに読む。
# Mistakes/(複数回発生ミスの観測ログ)も常時注入はせず MOC 経由のオンデマンド参照。
#
# 安全側設計: 注入の失敗でセッションを止めない。jq 不在 / vault 不在(業務 PC 等)/
# 想定外のエラーはすべて exit 0 で素通り(コンテキスト注入は best-effort)。
set -euo pipefail

command -v jq &>/dev/null || exit 0

# cwd から現在 repo の論理キーを導出し、MOC を現在 repo スコープへ絞る。
# 空(repo 外 / vault 直編集中)なら全 repo フォールバック(REPO_KEY="")。
input="$(cat)" || true
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
REPO_KEY=""
RESOLVER="$HOME/.claude/hooks/lib/resolve-repo-key.sh"
if [[ -n "$cwd" && -x "$RESOLVER" ]]; then
  REPO_KEY="$("$RESOLVER" "$cwd" 2>/dev/null || true)"
fi

VAULT="$HOME/obsidian/brain" # 全 PC 共通の固定パス
[[ -d "$VAULT" ]] || exit 0  # 未存在(業務 PC 等)→ 無音で素通り

MOC_MAX=800 # MOC 行数上限。Tier0 を実質定数に丸める

# --- MOC 索引の自動生成(.index/MOC.md) ---
# 注意: `... | head -n N` は head の早期終了で producer が SIGPIPE を受け、
# `set -o pipefail` 下では script 全体が落ちうる。これを避けるため生成側を
# awk で行数制限し、head にパイプしない(best-effort を壊さない)。
INDEX_DIR="$VAULT/.index"
MOC="$INDEX_DIR/MOC.md"
mkdir -p "$INDEX_DIR"
{
  echo "# MOC(自動生成 / $(date +%F)${REPO_KEY:+ / repo=$REPO_KEY}) — Tier1 本文は Grep/Glob + [[wikilink]] で必要分だけ読む"
  # 除外: _README.md(フォルダ説明の足場でノイズ)
  # Tasks/(delegate の作業ログ)は意図的に対象外 = MOC 非掲載 → Claude のコンテキストに
  # 載せない。時系列ログとして全部残すが、ノイズ源なので Tier0/グラフ/検索から隔離する。
  #
  # repo スコープフィルタ: Decisions/Mistakes は <type>/<repo>/ サブに住むため、現在 repo
  # セグメント or _shared のみ採用(他 repo は除外しノイズを減らす)。Knowledge/Preferences/
  # Projects は共有 flat なので常に採用。REPO_KEY 空(repo 外)なら全件採用(フォールバック)。
  # リンクは戦略X(bare basename・vault 全体一意前提)で出力 → ディレクトリ移動に強い。
  find "$VAULT/Knowledge" "$VAULT/Decisions" "$VAULT/Projects" "$VAULT/Mistakes" -name '*.md' ! -name '_README.md' -type f 2>/dev/null |
    sort | while IFS= read -r f; do
    rel="${f#"$VAULT"/}"
    case "$rel" in
    Decisions/*/* | Mistakes/*/*)
      seg="${rel#*/}"
      seg="${seg%%/*}"
      if [[ -n "$REPO_KEY" && "$seg" != "$REPO_KEY" && "$seg" != "_shared" ]]; then
        continue
      fi
      ;;
    esac
    name="$(basename -- "$rel")"
    name="${name%.md}"
    # title = 本文1行目見出し → 無ければ空 / meta = frontmatter tags+project を1行圧縮
    title="$(awk '/^# /{sub(/^# /,"");print;exit}' "$f")"
    meta="$(awk -F': ' '/^tags:|^project:/{printf "%s ",$2}' "$f")"
    printf -- "- [[%s]] %s%s\n" "$name" "${title:+$title }" "${meta:+($meta)}"
  done
} | awk -v max="$MOC_MAX" 'NR<=max' >"$MOC" # 生成側を制限(head 不使用で SIGPIPE 回避)

# --- Tier0 を additionalContext に注入 ---
BODY="$(
  echo "# 永続記憶(外部脳)Tier0 — 自動ロード。読込手順は hook が代行済み"
  echo "## Preferences(好み・作業スタイル)"
  # _README.md は除外: フォルダ説明の足場であり毎セッション注入する価値がない
  find "$VAULT/Preferences" -maxdepth 1 -name '*.md' ! -name '_README.md' -type f -exec cat {} + 2>/dev/null || true
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
