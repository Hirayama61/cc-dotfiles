#!/usr/bin/env bash
# test-patterns.sh — テストファイル/テストコード判定 ERE の単一情報源(参謀ゲート Phase 1)。
# block-test-deletion.sh(削除ブロック)と消失検知 Tier 1 以降(self-review プリステップ)が
# 同じ判定を共有する。
#
# bash 3.2 互換・source 時に set 状態を汚染しない(他 lib と同作法)。

# テストファイルのパス判定。grep -E / bash [[ =~ ]] 両対応の純 POSIX ERE。
test_file_ere() {
  printf '%s' '(\.(test|spec)\.[a-zA-Z]+|__tests__/|/tests?/)'
}

# テストコード(アサーション)の本文判定。\b と \s を含むため grep -E 専用
# (bash [[ =~ ]] では使えない)。
test_assertion_ere() {
  printf '%s' '\b(it|test|describe|expect|assert|cy)\s*[\.(]|\.(should|toBe|toEqual|toHaveBeenCalled|toThrow|toMatch|toContain)\s*\('
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  set -euo pipefail
  case "${1:-}" in
  file) test_file_ere ;;
  assertion) test_assertion_ere ;;
  *)
    echo "Usage: test-patterns.sh {file|assertion}" >&2
    exit 1
    ;;
  esac
  printf '\n'
fi
