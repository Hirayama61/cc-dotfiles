#!/usr/bin/env bash
# forensics 用の決定論的 redaction。tmux-claude-drive の付属部品で、失敗 pane の
# スクロールバックを書き出す運転元(パラメータ節「完了後の window/pane 処理」)が通す。
#
# 失敗 window の capture-pane スクロールバックを handoff / 別ログへ書き出す前に、
# トークン・資格情報らしき文字列を機械的にマスクし、行数上限を掛ける。モデルの善意に
# 頼らずコードで秘密衛生を強制する 1 段。**過剰マスク寄り(安全側)**に倒す。
# 注意: 行単位マスクなので、折り返しで分割されたトークンは取りこぼす。呼び出し側は
# `capture-pane -J`(折り返し結合)で渡すこと。best-effort であり、
# 短い/未知形式の秘密は残りうる。書き出し先ログは 0600・非共有 dir に置くこと。
#
# Usage: redact-forensics.sh [max_lines]   (stdin → 加工済みを stdout)
#   max_lines  末尾から残す行数(既定 500、または RLR_FORENSICS_MAX_LINES)。0 = 無制限。
set -euo pipefail

MAX_LINES="${1:-${RLR_FORENSICS_MAX_LINES:-500}}"
# 非負整数以外は安全側で既定 500 に倒す(不正値で上限が無効化=秘密の全量残留を防ぐ)。
case "$MAX_LINES" in
'' | *[!0-9]*) MAX_LINES=500 ;;
esac
# 桁数を先に制限(10# 算術自体のオーバーフローを避ける)→ 先頭ゼロを 10 進固定。
[ "${#MAX_LINES}" -gt 7 ] && MAX_LINES=1000000
MAX_LINES=$((10#$MAX_LINES))

input="$(cat)"

# 1) 行数上限(末尾を残す。失敗の証跡は末尾に出やすい)。
if [ "$MAX_LINES" -gt 0 ]; then
  total="$(printf '%s\n' "$input" | wc -l | tr -d ' ')"
  if [ "$total" -gt "$MAX_LINES" ]; then
    input="$(printf '[... redact-forensics: 先頭 %s 行を省略し末尾 %s 行のみ ...]\n%s' \
      "$((total - MAX_LINES))" "$MAX_LINES" "$(printf '%s\n' "$input" | tail -n "$MAX_LINES")")"
  fi
fi

# 2) 決定論的マスク。ラベル/名前付き秘密を先に、次に汎用の高エントロピー列。
#    BSD/GNU sed 両対応の POSIX ERE(-E)。BSD sed は -i(大小無視)非対応のため、
#    env 名は UPPER/lower を別ルールで列挙する(env ダンプは慣例上 UPPER が主)。
printf '%s\n' "$input" | sed -E \
  -e 's/(^|[^A-Za-z0-9_])[A-Za-z0-9_]*(PASSWORD|PASSWD|PWD|SECRET|SECRET_KEY|TOKEN|API_?KEY|APIKEY|ACCESS_?KEY|PRIVATE_?KEY|AUTH|CREDENTIAL)[[:space:]]*[:=][[:space:]]*("[^"]*"|'\''[^'\'']*'\''|[^[:space:]]+)/\1[REDACTED-secret-kv]/g' \
  -e 's/(^|[^A-Za-z0-9_])[a-z0-9_]*(password|passwd|pwd|secret|secret_key|token|api_?key|apikey|access_?key|private_?key|credential)[[:space:]]*[:=][[:space:]]*("[^"]*"|'\''[^'\'']*'\''|[^[:space:]]+)/\1[REDACTED-secret-kv]/g' \
  -e 's/("[A-Za-z0-9_.-]*([Pp]assword|[Pp]asswd|[Ss]ecret|[Tt]oken|[Aa]pi_?[Kk]ey|[Aa]pikey|[Aa]ccess_?[Kk]ey|[Aa]ccess_?[Tt]oken|[Aa]uth|[Cc]redential)[A-Za-z0-9_.-]*"[[:space:]]*:[[:space:]]*)"[^"]*"/\1"[REDACTED]"/g' \
  -e 's/([Aa]uthorization[[:space:]]*[:=][[:space:]]*)?([Bb]earer|[Bb]asic|[Dd]igest|[Tt]oken)[[:space:]]+[A-Za-z0-9._~+/=-]{4,}/[REDACTED-auth]/g' \
  -e 's/[Aa]uthorization[[:space:]]*[:=][[:space:]]*[A-Za-z0-9._~+/=-]{6,}/[REDACTED-auth]/g' \
  -e 's/eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}/[REDACTED-jwt]/g' \
  -e 's/sk-[A-Za-z0-9_-]{16,}/[REDACTED-token]/g' \
  -e 's/sk_(live|test)_[A-Za-z0-9]{10,}/[REDACTED-stripe]/g' \
  -e 's/gh[posru]_[A-Za-z0-9]{20,}/[REDACTED-gh-token]/g' \
  -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED-gh-pat]/g' \
  -e 's/glpat-[A-Za-z0-9_-]{16,}/[REDACTED-gitlab-pat]/g' \
  -e 's/xox[baprsce]-[A-Za-z0-9-]{10,}/[REDACTED-slack]/g' \
  -e 's/xapp-[0-9]-[A-Za-z0-9-]{10,}/[REDACTED-slack-app]/g' \
  -e 's/mfa\.[A-Za-z0-9_-]{20,}/[REDACTED-discord]/g' \
  -e 's/AKIA[0-9A-Z]{16}/[REDACTED-aws-akid]/g' \
  -e 's/AIza[A-Za-z0-9_-]{20,}/[REDACTED-google]/g' \
  -e 's/[A-Za-z0-9+/=_-]{40,}/[REDACTED-b64]/g' \
  -e 's/[0-9a-fA-F]{32,}/[REDACTED-hex]/g'
