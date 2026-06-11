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
# この ERE は移行元 block-test-deletion.sh のリテラルとバイト一致を維持する
# (PR #50 の挙動不変保証。検証ケース B2 が文字列一致を固定)。変更しないこと。
test_assertion_ere() {
  printf '%s' '\b(it|test|describe|expect|assert|cy)\s*[\.(]|\.(should|toBe|toEqual|toHaveBeenCalled|toThrow|toMatch|toContain)\s*\('
}

# ── 消失検知 Tier 1(増減カウント)用。JS/TS 先行・grep -E 専用 ──
# test_assertion_ere とは役割が違う(あちらは「テストコードか」の判定、こちらは
# 観点の単位を数えるカウンタ)ため分離。言語拡張はこの2関数に alternation を足す。

# テストケース/セクションの先頭(it/test/describe 呼び出し。.only/.skip/.each 等の
# modifier 付きも数える — modifier だけ消しても観点は減るため)。
test_case_ere() {
  printf '%s' '\b(it|test|describe)(\.[A-Za-z_]+)?[[:space:]]*\('
}

# アサーション呼び出し(expect/assert の直呼び・メソッド形式 + chai/jest チェーン)。
# assert.equal( 等の node:assert メソッドを漏らさないよう [.(] で受ける。
test_assert_ere() {
  printf '%s' '\b(expect|assert)[[:space:]]*[\.(]|\.(should|toBe|toEqual|toHaveBeenCalled|toThrow|toMatch|toContain)[[:space:]]*\('
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  set -euo pipefail
  case "${1:-}" in
  file) test_file_ere ;;
  assertion) test_assertion_ere ;;
  case) test_case_ere ;;
  assert) test_assert_ere ;;
  *)
    echo "Usage: test-patterns.sh {file|assertion|case|assert}" >&2
    exit 1
    ;;
  esac
  printf '\n'
fi
