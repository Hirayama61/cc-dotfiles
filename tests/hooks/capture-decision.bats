#!/usr/bin/env bats
# capture-decision.sh の E2E。
# PostToolUse(AskUserQuestion)で判断記録リマインダを additionalContext 注入する。
# 1 ctx 1 回に抑制(decision-nudged-${ctx} フラグ)。ctx 不明 / jq 不在は fail-open で
# 毎回注入=現状維持へ倒す。抑制は flag-paths.sh(単一情報源)経由で、rearm で再武装する。
#
# 注: decision-nudged はディスパッチャ未登録のため、フラグの seed/確認は hook 実行の
# 副作用(2 回目が抑制されるか)で検証する。@test タイトルは ASCII 限定
# (日本語タイトルは bats のテスト名解決が壊れる既知の罠)。

load ../helpers/common

setup() {
  install_hooks
  # 一時 HOME の外(実 XDG state dir)へフラグが漏れないよう明示的に落とす
  # (evolve-nudge-on-stop.bats と同作法。claude_flag_dir は絶対 XDG_STATE_HOME を優先)。
  unset XDG_STATE_HOME
}

# AskUserQuestion 風の入力 JSON を組み立てる。第1引数に transcript_path 断片(省略で無し)。
_ask_json() {
  local tp="${1:-}"
  if [[ -n "$tp" ]]; then
    printf '{"tool_name":"AskUserQuestion","transcript_path":"/tmp/tp/%s.jsonl","tool_input":{"questions":[{"question":"A or B?"}]}}' "$tp"
  else
    printf '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"A or B?"}]}}'
  fi
}

# additionalContext を持つ注入 JSON が出たことを確認する。
assert_injected() {
  jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"
    and (.hookSpecificOutput.additionalContext | type == "string" and length > 0)' \
    <<<"$output" >/dev/null
}

@test "injects additionalContext on first AskUserQuestion in a ctx" {
  run_hook capture-decision.sh "$(_ask_json sess-a)"
  [ "$status" -eq 0 ]
  assert_injected
  # 質問文が best-effort で添えられている。
  jq -e '.hookSpecificOutput.additionalContext | contains("A or B?")' <<<"$output" >/dev/null
}

@test "second AskUserQuestion in same ctx is suppressed (1 per ctx)" {
  run_hook capture-decision.sh "$(_ask_json sess-b)"
  assert_injected
  run_hook capture-decision.sh "$(_ask_json sess-b)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "different ctx injects again" {
  run_hook capture-decision.sh "$(_ask_json sess-c)"
  assert_injected
  run_hook capture-decision.sh "$(_ask_json sess-c2)"
  [ "$status" -eq 0 ]
  assert_injected
}

@test "rearm-coding-standards re-arms the nudge (re-inject after clear/compact)" {
  run_hook capture-decision.sh "$(_ask_json sess-d)"
  assert_injected
  run_hook capture-decision.sh "$(_ask_json sess-d)"
  [ -z "$output" ]
  run_hook rearm-coding-standards.sh '{"transcript_path":"/tmp/tp/sess-d.jsonl"}'
  [ "$status" -eq 0 ]
  run_hook capture-decision.sh "$(_ask_json sess-d)"
  [ "$status" -eq 0 ]
  assert_injected
}

@test "fail-open when jq is absent (no output, exit 0)" {
  run_hook_env "$(make_no_jq_path)" capture-decision.sh "$(_ask_json sess-e)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ctx missing always injects (suppression disabled, fail-open)" {
  run_hook capture-decision.sh "$(_ask_json)"
  [ "$status" -eq 0 ]
  assert_injected
  # ctx が取れないので 2 回目も抑制されず注入される。
  run_hook capture-decision.sh "$(_ask_json)"
  [ "$status" -eq 0 ]
  assert_injected
}

@test "non-AskUserQuestion tool is ignored" {
  run_hook capture-decision.sh '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
