#!/usr/bin/env bats
# 汎用スモーク: 全 hook に機械適用する fail-open 検証。
#
# Claude Code hook の遮断は exit 2 のみ(127 等の他の非ゼロは非ブロッキング=
# stderr 表示のみで実行継続)。よって fail-open の正しい判定基準は「exit != 2」。
# 無害入力・空入力・jq 不在のいずれでも、どの hook も exit 2 を返してはならない。
#
# PR-3 適用後の不変条件:
#   - block-secret-files は jq 不在でも exit 0(ガード追加済)。
#   - 共有 lib(hook-input.sh / resolve-git-target.sh)が構文破損しても、各 hook の
#     source_hook_lib 経路が握って exit 2 を出さない(A-1 修正の全 hook スモーク)。

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

@test "corrupt hook-input.sh: no hook blocks (subshell guard fail-open)" {
  # hook-input.sh が構文破損しても、各 hook 冒頭の subshell 試験 source が握って
  # fail-open(exit 2 を出さない)。`. "$LIB" 2>/dev/null || exit 0` 単独だと parse
  # エラーで exit 2 に化ける問題(self-review security 指摘)への回帰防止。
  printf '%s' '{ broken bash (' >"$HOME/.claude/hooks/lib/hook-input.sh"
  assert_no_block_for "corrupt-hook-input" \
    '{"tool_name":"Bash","tool_input":{"command":"git push"},"cwd":"/tmp"}'
}

@test "corrupt resolve-git-target.sh: no hook blocks (A-1 bare source fix)" {
  # かつて bare source していた git ゲート群が、resolve-git-target.sh の構文破損で
  # exit 2(ブロック)に化けた(A-1)。source_hook_lib 化でどの hook も exit 2 を出さない。
  printf '%s' '{ broken bash (' >"$HOME/.claude/hooks/lib/resolve-git-target.sh"
  assert_no_block_for "corrupt-resolve-git-target" \
    '{"tool_name":"Bash","tool_input":{"command":"git push --force"},"cwd":"/tmp"}'
}

@test "corrupt context-paths.sh: no hook blocks (context-pressure fail-open)" {
  # context-pressure 系 6 hook が source する context-paths.sh の構文破損でも、
  # source_hook_lib の subshell 試験が握りどの hook も exit 2 を出さない。
  printf '%s' '{ broken bash (' >"$HOME/.claude/hooks/lib/context-paths.sh"
  assert_no_block_for "corrupt-context-paths" \
    '{"tool_name":"Edit","transcript_path":"/tmp/ctx-x.jsonl","tool_input":{"file_path":"/tmp/f"},"cwd":"/tmp"}'
}
