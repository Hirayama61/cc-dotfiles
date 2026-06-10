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

# stdin のテキストを max バイトに截断して出力し、上限到達/接近で警告 callout を付す。
# Preferences とガイドの両パーツを共通化し、注入の有界化を統一する。
# 截断は here-string(`head -c <<<`)で行う: 外部プロデューサ無しで SIGPIPE が起きず、
# `set -euo pipefail` 下でも printf|head の早期 close による中断(141)を避けられる。
# 引換えに here-string は末尾改行を1個増やすが、注入本文では許容する。
# バイト計測は `wc -c`(${#var} は文字数で多バイト日本語のバイト上限判定に不正)。
emit_capped() {
  local label="$1" action_hint="$2" max="$3" text bytes soft
  text="$(cat)"
  bytes="$(printf '%s' "$text" | wc -c | tr -d ' ')"
  soft=$(( max * 75 / 100 ))
  # head -c はバイト単位截断なので截断点で UTF-8 多バイト文字が割れ末尾に壊れバイトが
  # 残る。iconv -c で不完全バイトを落とし注入を妥当な UTF-8 に保つ。iconv 不在なら素出力。
  if command -v iconv >/dev/null 2>&1; then
    head -c "$max" <<<"$text" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true
  else
    head -c "$max" <<<"$text"
  fi
  if (( bytes >= max )); then
    echo
    echo "> [!warning] ${label}: 注入上限 ${max}B に到達し一部を截断した(以降は欠落)。${action_hint}。"
  elif (( bytes >= soft )); then
    echo
    echo "> [!warning] ${label}: 注入上限に接近(${bytes}/${max}B)。${action_hint}。"
  fi
}

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
  # _README.md は除外: フォルダ説明の足場であり毎セッション注入する価値がない。
  # 連結順を LC_ALL=C sort -z で固定し截断結果を決定的に。-print0/-z/-0 で改行入り
  # ファイル名でも区切りが崩れない(NUL 区切り)。末尾 `|| true` は安全契約: producer
  # 失敗(race/権限なし等)で pipefail が立っても BODY 代入を止めず exit 0 で素通る。
  find "$VAULT/Preferences" -maxdepth 1 -name '*.md' ! -name '_README.md' -type f -print0 2>/dev/null \
    | LC_ALL=C sort -z \
    | xargs -0 cat 2>/dev/null \
    | emit_capped "Preferences" "上限到達なら link 化(Phase2)を検討" "$TIER0_MAX_BYTES" \
    || true
  if [[ -n "$GUIDE" ]]; then
    echo
    echo "## 生きたガイド($REPO_KEY)— 最新の運用知。詳細サブは [[link]]/Grep でオンデマンド"
    # 末尾 `|| true`: cat 失敗(race/権限なし等)でも安全契約を守り素通る。
    cat "$GUIDE" 2>/dev/null \
      | emit_capped "生きたガイド($REPO_KEY)" "root を削って小さく保て" "$TIER0_MAX_BYTES" \
      || true
  fi
)"

jq -n --arg body "$BODY" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $body
  }
}' || exit 0

exit 0
