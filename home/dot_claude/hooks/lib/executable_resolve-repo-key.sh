#!/usr/bin/env bash
# resolve-repo-key.sh — 対象パス or cwd から「論理 repo キー」を導出する単一情報源。
#
# doc-gravity ブロック hook / SessionStart MOC / obsidian-reviewer が同一の
# 写像(cwd→repo キー)を共有するためのライブラリ兼実行スクリプト。
#
# 導出規則(汎用・enum ハードコードしない):
#   1. 入力がディレクトリならそのまま、ファイル(or 非存在)なら dirname を基点にする。
#   2. git --git-common-dir を取り、その親ディレクトリの basename を論理キーとする。
#      common-dir は worktree でも**メイン clone の .git** を指すため、フラット worktree
#      (~/worktrees/host/owner/repo/<branch>)でもキーが branch 名ではなく repo 名
#      (cc-dotfiles 等)になる。--show-toplevel の basename だと worktree では branch
#      leaf になってしまい frontmatter `project:` 論理名と一致しない(実測で確認)ため
#      common-dir 親を採用した。既存 project 値 dotfiles/cc-dotfiles/agent-sandbox と一致。
#   3. git 外で common-dir が取れなければ ghq レイアウト(.../owner/repo)から
#      owner-repo をフォールバック導出する。
#   4. いずれも解けなければ空文字を返す(呼び出し側が安全側=素通し/全 repo で扱う)。
#
# 出力 = 論理 repo キー(stdout 1行、改行なし)。macOS ファイル名で安全な文字へ正規化。
#
# 使い方:
#   source .../resolve-repo-key.sh && resolve_repo_key "/path/or/cwd"
#   または直接実行: resolve-repo-key.sh "/path/or/cwd"
set -euo pipefail

# キーを macOS ディレクトリ名で安全な形へ正規化する。
#   - 前後空白除去 → 内部空白をハイフン化
#   - パス区切り(/ \)と制御文字・コロンを除去/ハイフン化
#   - 小文字化はしない(git repo 名の大小をそのまま尊重。既存キーは cc-dotfiles 等)
#   - NFC 統一(macOS の NFD 化対策。python3 不在なら素通し=basename は ASCII 想定)
_normalize_repo_key() {
  local key="$1"
  # 前後の空白を除去
  key="${key#"${key%%[![:space:]]*}"}"
  key="${key%"${key##*[![:space:]]}"}"
  # 空白 → ハイフン、パス区切り/コロン → ハイフン
  key="${key//[[:space:]]/-}"
  key="${key//\//-}"
  key="${key//\\/-}"
  key="${key//:/-}"
  # 制御文字を除去(tr が無い環境はまず無いが best-effort)
  if command -v tr >/dev/null 2>&1; then
    key="$(printf '%s' "$key" | tr -d '[:cntrl:]')"
  fi
  # パストラバーサル防御: キーは Tasks/<repo>・Decisions/<repo> の実ディレクトリ生成に
  # 使われるため `..` と先頭ドットを無害化する(`/` は上で除去済みだが `..` や `.foo`・
  # `..` 単体は残りうる)。extglob 非依存にするため先頭ドットはループで剥がす。
  key="${key//../_}"
  while [[ "$key" == .* ]]; do key="${key#.}"; done
  # NFC 正規化(python3 があれば)
  if [[ -n "$key" ]] && command -v python3 >/dev/null 2>&1; then
    key="$(python3 -c 'import sys,unicodedata; sys.stdout.write(unicodedata.normalize("NFC", sys.argv[1]))' "$key" 2>/dev/null || printf '%s' "$key")"
  fi
  printf '%s' "$key"
}

resolve_repo_key() {
  local input="${1:-$PWD}"
  local base

  # ディレクトリならそのまま、それ以外(ファイル/非存在)は dirname を基点に。
  if [[ -d "$input" ]]; then
    base="$input"
  else
    base="$(dirname -- "$input")"
  fi

  local common_dir key=""
  common_dir="$(git -C "$base" rev-parse --git-common-dir 2>/dev/null || true)"

  if [[ -n "$common_dir" ]]; then
    # common-dir は -C 起点からの相対(例 .git)で返りうるので絶対化してから親を取る。
    case "$common_dir" in
    /*) ;;
    *) common_dir="$base/$common_dir" ;;
    esac
    local repo_root
    repo_root="$(cd "$common_dir/.." 2>/dev/null && pwd || true)"
    [[ -n "$repo_root" ]] && key="$(basename -- "$repo_root")"
  fi

  if [[ -z "$key" ]]; then
    # フォールバック: ghq レイアウト(.../owner/repo)から owner-repo を導出。
    # 基点を遡って ghq ルート相対の最後2セグメントを拾う。
    case "$base" in
    "$HOME"/ghq/*)
      local rel="${base#"$HOME"/ghq/}"
      # rel = <host>/<owner>/<repo>[/...]。先頭 host を落とし owner/repo を取る。
      local owner repo
      local -a _segs
      IFS='/' read -r -a _segs <<<"$rel"
      if [[ ${#_segs[@]} -ge 3 ]]; then
        owner="${_segs[1]}"
        repo="${_segs[2]}"
        key="${owner}-${repo}"
      elif [[ ${#_segs[@]} -ge 2 ]]; then
        # host/owner だけ等の不完全形は repo セグメントを優先
        key="${_segs[1]}"
      fi
      ;;
    esac
  fi

  [[ -z "$key" ]] && {
    printf ''
    return 0
  }
  _normalize_repo_key "$key"
}

# 直接実行されたとき(source ではないとき)だけ引数で実行する。
# set -u 下で source されても落ちないよう BASH_SOURCE 参照に既定値を与える。
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  resolve_repo_key "${1:-$PWD}"
  printf '\n'
fi
