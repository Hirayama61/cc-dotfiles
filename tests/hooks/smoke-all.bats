#!/usr/bin/env bats
# 汎用スモーク: 全 hook に機械適用する fail-open 検証。
#
# Claude Code hook の遮断は exit 2 のみ(127 等の他の非ゼロは非ブロッキング=
# stderr 表示のみで実行継続)。よって fail-open の正しい判定基準は「exit != 2」。
# 無害入力・空入力・jq 不在のいずれでも、どの hook も exit 2 を返してはならない。
#
# 既知の現状(PR-3 で改善予定。ここでは「exit != 2 は満たす=ブロックしない」ことだけ固定):
#   - block-secret-files / pipe-stage-permissions は jq 不在で exit 127(noisy だが非ブロック)。
#   - lib 破損時に exit 2 へ化ける bare source の検証は smoke では扱わず、
#     代表 E2E(block-no-verify.bats)で現状を固定し PR-3 で red→green 化する。

load ../helpers/common

setup() {
  install_hooks
}

# 全 hook に同一入力を流し、exit 2(ブロック)を返した hook を集めて報告する。
assert_no_block_for() {
  local label="$1" json="$2" path_override="${3:-}"
  local hook offenders=""
  while IFS= read -r hook; do
    [[ -n "$hook" ]] || continue
    if [[ -n "$path_override" ]]; then
      run_hook_env "$path_override" "$hook" "$json"
    else
      run_hook "$hook" "$json"
    fi
    if [[ "$status" -eq 2 ]]; then
      offenders+=" $hook(exit2)"
    fi
  done < <(list_installed_hooks)
  if [[ -n "$offenders" ]]; then
    echo "[$label] 以下の hook がブロック(exit 2)した:$offenders"
    return 1
  fi
}

@test "harmless Bash input: no hook blocks" {
  # 無害な Bash 入力でどの hook もブロックしない
  assert_no_block_for "harmless-bash" \
    '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"cwd":"/tmp"}'
}

@test "harmless Edit input: no hook blocks" {
  # 無害な Edit 入力でどの hook もブロックしない
  assert_no_block_for "harmless-edit" \
    '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x.txt","old_string":"a","new_string":"b"},"cwd":"/tmp"}'
}

@test "empty stdin: no hook blocks" {
  # 空 stdin でどの hook もブロックしない
  assert_no_block_for "empty-stdin" ""
}

@test "broken JSON: no hook blocks" {
  # 不正 JSON でどの hook もブロックしない
  assert_no_block_for "broken-json" 'not a json {{{'
}

@test "no jq: no hook blocks (no exit 2)" {
  # jq 不在でもどの hook もブロックしない(exit 2 を出さない)
  local nojq
  nojq="$(make_no_jq_path)"
  assert_no_block_for "no-jq" \
    '{"tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/tmp"}' "$nojq"
}
