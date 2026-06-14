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

# Tier0 各パーツの注入上限(バイト)。ルートを小さく保つ規律が破れても注入を有界にする。
TIER0_MAX_BYTES=20000

# stdin を max バイトで截断して出力し、上限到達/接近(75%)で警告 callout を付す。
# Preferences とガイドの有界化を共通化する(PR #35 の設計を後継)。stdin からは
# max+1 バイトしか読まないためメモリも有界。供給側の非ゼロ終了(SIGPIPE 由来の 141 /
# xargs の 1 等)は呼び出し側パイプラインの || true で吸収する。截断で割れた UTF-8
# 末尾は iconv -c が除去(${var:0:N} はロケール依存で不可)。iconv 不在なら截断のみで
# 素通し(その場合の割れ末尾の扱いは最終段 jq に委ねる。失敗しても fail-open)。
emit_capped() {
  local label="$1" action_hint="$2" max="$3" text bytes out
  [[ "$max" =~ ^[0-9]+$ ]] || return 0
  # 番兵 x で末尾改行を保存する(コマンド置換は末尾改行を剥がすため、max+1 バイト目が
  # 改行だと bytes が max 以下に縮み、截断したのに到達 callout が出ない偽陰性になる)。
  text="$(head -c "$((max + 1))" 2>/dev/null || true; printf x)"
  text="${text%x}"
  bytes="$(printf '%s' "$text" | wc -c | tr -d ' ')"
  if command -v iconv >/dev/null 2>&1; then
    out="$(printf '%s' "$text" | head -c "$max" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || true)"
  else
    out="$(printf '%s' "$text" | head -c "$max" || true)"
  fi
  printf '%s\n' "$out"
  if ((bytes > max)); then
    printf '\n> [!warning] %s: 注入上限 %sB に到達し以降を截断した。%s。\n' "$label" "$max" "$action_hint"
  elif ((bytes >= max * 75 / 100)); then
    printf '\n> [!warning] %s: 注入上限に接近(%s/%sB)。%s。\n' "$label" "$bytes" "$max" "$action_hint"
  fi
}

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0

# cwd から現在 repo の論理キーを導出し、注入するルートガイドを現在 repo に対応づける。
# 空(repo 外 / vault 直編集中)ならガイドは注入せず Preferences のみ(REPO_KEY="")。
cwd="$(hook_cwd)"
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
  # _README.md は除外: フォルダ説明の足場であり毎セッション注入する価値がない。
  # LC_ALL=C sort -z で連結順を固定し、截断結果を環境非依存で決定的に保つ。
  find "$VAULT/Preferences" -maxdepth 1 -name '*.md' ! -name '_README.md' -type f -print0 2>/dev/null |
    LC_ALL=C sort -z | xargs -0 cat 2>/dev/null |
    emit_capped "Preferences" "全文は ~/obsidian/brain/Preferences/ を直接読む。肥大が続くなら link 化(Phase2)を検討" "$TIER0_MAX_BYTES" ||
    true
  if [[ -n "$GUIDE" ]]; then
    echo
    echo "## 生きたガイド($REPO_KEY)— 最新の運用知。詳細サブは [[link]]/Grep でオンデマンド"
    cat "$GUIDE" 2>/dev/null |
      emit_capped "生きたガイド($REPO_KEY)" "root を削って小さく保つ" "$TIER0_MAX_BYTES" ||
      true
  fi
)"

jq -n --arg body "$BODY" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $body
  }
}' || exit 0

exit 0
