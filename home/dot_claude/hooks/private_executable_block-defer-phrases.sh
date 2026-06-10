#!/usr/bin/env bash
# PreToolUse(Bash): PR/issue コメント・コミットメッセージの「本文」に先送り表明
# (defer フレーズ)があり、かつ追跡参照(#番号)を伴わないとき exit 2 でブロックする。
# 「後で対応 / 次の PR で / out of scope」等の silent punting を、honest な先送り
# (#123 等で追跡を明示する場合)と区別して止める。「黙って作業を落とす」行為の言語版。
#
# 対象は gh pr comment / gh pr review / gh issue comment / git commit の「本文だけ」。
# 検出を本文(-m/--message/-b/--body の値)に閉じる理由: コマンド構造の番号(PR 指定の
# #42 等)を追跡参照と誤認しないため、かつコマンド名・パス等の技術的に正当な語を
# 誤検出しないため。判定は split_git_segments のセグメント単位で行い、チェーンされた
# 別コマンドの本文との混線を防ぐ。
#
# best-effort な抑止であり敵対防御ではない: 本文がコマンド文字列に現れないケース
# ── `--body-file`/`-F`(ファイル経由)・`-m` 無し `git commit`(エディタ起動)・
# `$(...)`/heredoc 展開前 ── は本文が見えず素通る。`split_git_segments` は env 値内や
# 本文中の `&;|()` をクォート無視で誤分割し、後半のフレーズを取りこぼしうる(検出漏れ
# 方向 = fail-open)。クォートで囲んだフラグ(`"--body"`)の本文抽出も対象外。これらは
# 既存 hook 群と同じく「うっかり silent punting」の抑止が目的で、意図的な回避の遮断ではない。
set -euo pipefail

command -v jq &>/dev/null || exit 0
input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
[[ -z "$cmd" ]] && exit 0

LIB="$HOME/.claude/hooks/lib/resolve-git-target.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
. "$LIB"

# heredoc 本文(ドキュメント書き出し中のコマンド例等)への誤爆を防ぐ(dotfiles#74 と同作法)。
if type strip_heredocs >/dev/null 2>&1; then
  stripped="$(strip_heredocs "$cmd" 2>/dev/null || true)"
  [[ -n "$stripped" ]] && cmd="$stripped"
fi

# 日本語 defer フレーズの grep を確実にするためロケールを固定(旧 block-defer-phrases 踏襲)。
export LC_ALL=en_US.UTF-8

# defer フレーズ(JP/EN)。抽出した本文に対し grep -iE で照合する。
# `defer to X`(X に従う)は正当な技術表現のため、先送りの語形だけに絞る。
DEFER_PHRASES='後で対応|あとで対応|次のPRで|別PRで|別のPRで|一旦スキップ|いったんスキップ|時間があれば|余裕があれば|will fix later|fix later|in a follow-up|follow-up PR|followup PR|punt|defer (to|until) (later|next|the next|a follow)|out of scope'

# gh サブコマンド検出の字句は block-gh-mutations.sh と同一(quote-aware・whole-segment ERE)。
# サブコマンド前のグローバルフラグ / 前置 env 代入 / コマンド境界を許容する。
FLAGS='(-{1,2}[A-Za-z][A-Za-z0-9-]*(=\S+)?\s+([^-\s]\S*\s+)?)*'
ENV='([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*'
BORDER='(^|[;&|(])[[:space:]]*'
END='(\s|$|[;&|)])'

# セグメントが defer-phrases の対象操作か判定する。
# git commit はサブコマンド厳密一致、gh 系は正規化セグメントへ whole-segment ERE。
_is_target_segment() {
  local seg="${1:-}" norm
  [[ "$(git_subcommand_of_segment "$seg")" == "commit" ]] && return 0
  norm="$(normalized_words_of_segment "$seg")"
  printf '%s\n' "$norm" | grep -qE "${BORDER}${ENV}gh\s+${FLAGS}pr\s+(comment|review)${END}" && return 0
  printf '%s\n' "$norm" | grep -qE "${BORDER}${ENV}gh\s+${FLAGS}issue\s+comment${END}" && return 0
  return 1
}

# セグメント内の本文(-m/--message/-b/--body の値)を抽出して空白連結で返す。
# クォート対応(多語の値 "out of scope" / "後で対応" を1値として保つ)のため、
# トークン分割でなく raw セグメントへ grep -oE をかけ「フラグ + 値」を取り出してから
# 値部を切り出す。値は "..." / '...' / bareword を許容。複数 -m は全結合する。
# read -r -a によるトークン分割だと "out of scope" 等の多語値を途中で落とすため不採用。
_body_text_of_segment() {
  local seg="${1:-}" out="" m val
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    # m 例: --body "後で対応" / -m='fix later' / -am "msg"(束ねフラグ)/ -m"密着クォート"
    # フラグ部を剥がして値を取り出し、前後のクォート1段を除去する。
    val="$(printf '%s' "$m" | sed -E 's/^(-[A-Za-z]*m|--message|-[A-Za-z]*b|--body)(=|[[:space:]]+)?//')"
    val="${val#[\"\']}"
    val="${val%[\"\']}"
    out="${out:+$out }$val"
  done < <(printf '%s\n' "$seg" |
    grep -oE "(-[A-Za-z]*m|--message|-[A-Za-z]*b|--body)((=|[[:space:]]+)(\"[^\"]*\"|'[^']*'|[^[:space:]]+)|(\"[^\"]*\"|'[^']*'))")
  printf '%s' "$out"
}

while IFS= read -r seg; do
  [[ -z "$seg" ]] && continue
  _is_target_segment "$seg" || continue

  body="$(_body_text_of_segment "$seg")"
  # 本文がコマンド文字列に無い(file/エディタ/コマンド置換経由)→ 検出スキップ(fail-open)。
  [[ -z "$body" ]] && continue

  # 追跡参照(#番号)が本文にあれば honest な先送りとして通す。
  printf '%s\n' "$body" | grep -qE '#[0-9]+' && continue
  # lib の括弧分割(dotfiles#72)により本文中の「(#123 で追跡)」が別セグメントへ
  # 割れて body から消えるため、raw cmd への fallback 照合で取りこぼしを防ぐ。
  # パターンを「(#番号」に絞るのは、裸の #番号 だと hex 色コード・シェルコメント・
  # チェーン中の別コマンドで defer 検出が恒常無効化されるため(動機ケース限定の緩和)。
  printf '%s' "$cmd" | grep -qE '\(#[0-9]+' && continue

  if printf '%s\n' "$body" | grep -qiE "$DEFER_PHRASES"; then
    matched="$(printf '%s\n' "$body" | grep -ioE "$DEFER_PHRASES" || true)"
    matched="${matched%%$'\n'*}"
    echo "ブロック: コメント/コミット本文の先送り表現「${matched}」を検出。今のスコープで解決するか、#番号で追跡参照を伴わせること。" >&2
    exit 2
  fi
done < <(split_git_segments "$cmd")

exit 0
