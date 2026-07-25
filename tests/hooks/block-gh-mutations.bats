#!/usr/bin/env bats
# block-gh-mutations.sh の E2E。外向き/不可逆な gh サブコマンド(pr の
# ready/merge/close/reopen・release の create/delete/edit/upload・repo の
# delete/archive/edit)を止め、read-only な gh と対象外(gh api)を通すことを固定する。
#
# 遮断は exit 2 のみ。fail-open の判定は「exit != 2」(このリポの規約)。
# pr / release / repo は独立した3分岐で、status だけでは「別分岐が発火した」型の退行を
# 検知できないため、各分岐の代表テストでブロックメッセージも突き合わせる。

load ../helpers/common

setup() {
  install_hooks
}

@test "blocks gh pr merge" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 123 --squash"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'gh pr の'
}

@test "blocks gh pr ready" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr ready 123"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr close" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr close 123"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr reopen" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr reopen 123"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr merge behind a global flag with a value" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh -R owner/repo pr merge 1"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr merge behind a --flag=value" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh --repo=owner/repo pr merge 1"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr merge behind an env assignment" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"PAGER=cat gh pr merge 1"}}'
  [ "$status" -eq 2 ]
}

@test "blocks a quoted merge subcommand" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr \"merge\" 1"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr merge after a command separator" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr view 1 && gh pr merge 1"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh release create" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh release create v1.0.0"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'gh release の'
}

@test "blocks gh release delete" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh release delete v1.0.0"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh release edit" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh release edit v1.0.0 --draft=false"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'gh release の'
}

@test "blocks gh release upload" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh release upload v1.0.0 dist/app.zip"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'gh release の'
}

@test "blocks gh repo delete" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh repo delete owner/repo"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'gh repo の'
}

@test "blocks gh repo archive" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh repo archive owner/repo"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh repo edit" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh repo edit --visibility private"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'gh repo の'
}

@test "allows read-only gh pr commands" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr view 123 --json state"}}'
  [ "$status" -eq 0 ]
}

@test "allows gh pr list" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr list --limit 10"}}'
  [ "$status" -eq 0 ]
}

@test "allows gh pr create" {
  # PR 作成は外向きだが対象外(ready/merge/close/reopen のみが不可逆な状態変更)。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr create --fill"}}'
  [ "$status" -eq 0 ]
}

@test "allows gh release view" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh release view v1.0.0"}}'
  [ "$status" -eq 0 ]
}

@test "allows gh repo view" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh repo view owner/repo"}}'
  [ "$status" -eq 0 ]
}

@test "accepted gap: gh api is out of scope" {
  # gh api は read-only な GET を多く含み誤検知が多いため意図的に非対象(hook ヘッダ)。
  # `accepted gap:` 接頭辞は「hook が守れていないと合意済みの穴」の機械的な目印。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh api -X DELETE repos/owner/repo/issues/1"}}'
  [ "$status" -eq 0 ]
}

@test "no false positive: gh pr merge mentioned mid-command is allowed" {
  # BORDER が「コマンド開始位置の gh」に限定するため、引数中の言及では発火しない。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"echo run gh pr merge later >> notes.txt"}}'
  [ "$status" -eq 0 ]
}

@test "guarded source: corrupt resolve-git-target lib fails open (exit != 2)" {
  echo "{ broken bash (" >"$HOME/.claude/hooks/lib/resolve-git-target.sh"
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 1"}}'
  [ "$status" -ne 2 ]
}

@test "fails open without jq (exit != 2)" {
  local nojq
  nojq="$(make_no_jq_path)"
  run_hook_env "$nojq" block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 1"}}'
  [ "$status" -ne 2 ]
}
