#!/usr/bin/env bats
# inject-guide-review.sh の characterization。
# PreToolUse(Skill) と UserPromptSubmit の 2 経路で、diff レビュー系 skill の発動時に
# 「ガイドが存在する repo でだけ」guide-reviewer 起動指示を注入することを固定する。

load ../helpers/common

setup() {
  install_hooks
  REPO="$HOME/repos/myrepo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  GUIDE_DIR="$HOME/obsidian/brain/Guides/myrepo"
}

# ガイドを実在させる(repo キー = git common-dir の親 basename = myrepo)。
make_guide() {
  mkdir -p "$GUIDE_DIR"
  printf '# myrepo guide\n' >"$GUIDE_DIR/myrepo-ガイド.md"
}

pretooluse_json() {
  printf '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"%s"},"cwd":"%s"}' "$1" "$REPO"
}

prompt_json() {
  printf '{"hook_event_name":"UserPromptSubmit","prompt":"%s","cwd":"%s"}' "$1" "$REPO"
}

@test "PreToolUse Skill self-review with guide: injects guide-reviewer instruction" {
  make_guide
  run_hook inject-guide-review.sh "$(pretooluse_json self-review)"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'guide-reviewer'
  echo "$output" | grep -qF 'myrepo-ガイド.md'
  echo "$output" | grep -qF '"hookEventName": "PreToolUse"'
  # 出力は untrusted 扱いの指示を含む(finding のみ取り込む)
  echo "$output" | grep -qF 'untrusted'
}

@test "PreToolUse Skill self-review without guide: silent passthrough" {
  run_hook inject-guide-review.sh "$(pretooluse_json self-review)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "PreToolUse Skill design-review: not a diff review, silent" {
  make_guide
  run_hook inject-guide-review.sh "$(pretooluse_json design-review)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "PreToolUse Skill coderabbit:code-review: namespace-qualified target injects" {
  make_guide
  run_hook inject-guide-review.sh "$(pretooluse_json coderabbit:code-review)"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'guide-reviewer'
}

@test "PreToolUse Skill coderabbit:autofix: fix skill, silent" {
  make_guide
  run_hook inject-guide-review.sh "$(pretooluse_json coderabbit:autofix)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "subagent origin (agent_id present): silent" {
  make_guide
  run_hook inject-guide-review.sh \
    "$(printf '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"self-review"},"agent_id":"a1","cwd":"%s"}' "$REPO")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "UserPromptSubmit slash command with args: injects with matching hookEventName" {
  make_guide
  run_hook inject-guide-review.sh "$(prompt_json '  /self-review high')"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'guide-reviewer'
  echo "$output" | grep -qF '"hookEventName": "UserPromptSubmit"'
}

@test "UserPromptSubmit builtin /code-review: injects" {
  make_guide
  run_hook inject-guide-review.sh "$(prompt_json '/code-review')"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'guide-reviewer'
}

@test "UserPromptSubmit mid-text mention: not a slash command, silent" {
  make_guide
  run_hook inject-guide-review.sh "$(prompt_json 'あとで /self-review して')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "UserPromptSubmit /simplify: fix skill, silent" {
  make_guide
  run_hook inject-guide-review.sh "$(prompt_json '/simplify')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unknown hook_event_name: silent" {
  make_guide
  run_hook inject-guide-review.sh \
    "$(printf '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"self-review"},"cwd":"%s"}' "$REPO")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no jq: silent passthrough (fail-open)" {
  make_guide
  local nojq
  nojq="$(make_no_jq_path)"
  run_hook_env "$nojq" inject-guide-review.sh "$(pretooluse_json self-review)"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}
