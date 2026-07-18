#!/usr/bin/env bats
# block-unreviewed-mutation.sh(設計レビューゲート Gate 2)の E2E。
#
# 2026-07-11 監査トリアージ 争点2 でブロック(exit 2)から警告注入へ格下げ。
# 未通過のコード repo 編集では additionalContext に警告を注入し、編集は通す
# (exit 0・exit 2 を返さない)。警告は 1 ctx 1 回(design-gate-warned-${ctx})に抑制し、
# rearm-coding-standards(clear|compact)で再武装する。design-reviewed / trivial-override
# フラグがあれば無音で通す(design-gate.sh の共有判定は不変)。
#
# @test タイトルは ASCII 限定(日本語タイトルは bats のテスト名解決が壊れる既知の罠)。

load ../helpers/common

setup() {
  install_hooks
  # 一時 HOME の外(実 XDG state dir)へフラグが漏れないよう明示的に落とす。
  unset XDG_STATE_HOME

  FLAG="$HOME/.claude/hooks/lib/flag-paths.sh"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name t
  git -C "$REPO" checkout -q -b feature/gate2
  ( cd "$REPO" && : >f.txt && git add f.txt && git -c core.hooksPath=/dev/null commit -qm init )
  REPO_KEY="$("$HOME/.claude/hooks/lib/resolve-repo-key.sh" "$REPO")"
}

# Edit 入力 JSON。第1引数 = transcript_path 断片(省略で無し=ctx 空)。
_edit_json() {
  local tp="${1:-}"
  if [[ -n "$tp" ]]; then
    printf '{"tool_name":"Edit","transcript_path":"/tmp/tp/%s.jsonl","tool_input":{"file_path":"%s/f.txt","old_string":"","new_string":"x"}}' "$tp" "$REPO"
  else
    printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/f.txt","old_string":"","new_string":"x"}}' "$REPO"
  fi
}

# additionalContext を持つ PreToolUse 注入 JSON が出たことを確認する。
assert_warned() {
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"
    and (.hookSpecificOutput.additionalContext | type == "string" and length > 0)' \
    <<<"$output" >/dev/null
}

write_design_reviewed() {
  "$FLAG" dir-ensure
  touch "$("$FLAG" design-reviewed "$REPO_KEY" feature/gate2)"
}

@test "never blocks: unreviewed edit returns non-2 (warn, not block)" {
  run_hook block-unreviewed-mutation.sh "$(_edit_json sess-a)"
  [ "$status" -ne 2 ]
  [ "$status" -eq 0 ]
  assert_warned
}

@test "warns once per ctx: second edit in same ctx is suppressed" {
  run_hook block-unreviewed-mutation.sh "$(_edit_json sess-b)"
  assert_warned
  run_hook block-unreviewed-mutation.sh "$(_edit_json sess-b)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "different ctx warns again" {
  run_hook block-unreviewed-mutation.sh "$(_edit_json sess-c)"
  assert_warned
  run_hook block-unreviewed-mutation.sh "$(_edit_json sess-c2)"
  [ "$status" -eq 0 ]
  assert_warned
}

@test "rearm-coding-standards re-arms the warning after clear/compact" {
  run_hook block-unreviewed-mutation.sh "$(_edit_json sess-d)"
  assert_warned
  run_hook block-unreviewed-mutation.sh "$(_edit_json sess-d)"
  [ -z "$output" ]
  run_hook rearm-coding-standards.sh '{"transcript_path":"/tmp/tp/sess-d.jsonl"}'
  [ "$status" -eq 0 ]
  run_hook block-unreviewed-mutation.sh "$(_edit_json sess-d)"
  [ "$status" -eq 0 ]
  assert_warned
}

@test "design-reviewed flag passes silently (no warn)" {
  write_design_reviewed
  run_hook block-unreviewed-mutation.sh "$(_edit_json sess-e)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "reason-tagged trivial-override suppresses the warning" {
  "$FLAG" dir-ensure
  printf '%s\n' 'reviewed by human' > "$("$FLAG" trivial-override-pending "$REPO_KEY")"
  run_hook block-unreviewed-mutation.sh "$(_edit_json sess-f)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "empty trivial-override does not suppress (warns)" {
  "$FLAG" dir-ensure
  : > "$("$FLAG" trivial-override-pending "$REPO_KEY")"
  run_hook block-unreviewed-mutation.sh "$(_edit_json sess-g)"
  [ "$status" -eq 0 ]
  assert_warned
}

@test "ctx missing always warns (suppression disabled, fail-open)" {
  run_hook block-unreviewed-mutation.sh "$(_edit_json)"
  [ "$status" -eq 0 ]
  assert_warned
  run_hook block-unreviewed-mutation.sh "$(_edit_json)"
  [ "$status" -eq 0 ]
  assert_warned
}

@test "relative file_path is passed through silently" {
  run_hook block-unreviewed-mutation.sh \
    '{"tool_name":"Edit","transcript_path":"/tmp/tp/sess-h.jsonl","tool_input":{"file_path":"rel/x.txt","old_string":"","new_string":"x"}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "non-repo absolute path is passed through silently" {
  run_hook block-unreviewed-mutation.sh \
    '{"tool_name":"Edit","transcript_path":"/tmp/tp/sess-i.jsonl","tool_input":{"file_path":"'"$BATS_TEST_TMPDIR"'/norepo/x.txt","old_string":"","new_string":"x"}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fail-open when jq is absent (no output, exit 0)" {
  run_hook_env "$(make_no_jq_path)" block-unreviewed-mutation.sh "$(_edit_json sess-j)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
