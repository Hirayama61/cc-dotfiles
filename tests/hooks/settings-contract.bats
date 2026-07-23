#!/usr/bin/env bats
# settings.json.tmpl の契約テスト。
# テンプレートのプレースホルダを差し替えて JSON として解釈し、hook 登録の不変条件を検証する:
#   - hooks セクションが参照する全 command パスが実在する hook ソースに対応する。
# chezmoi を呼ばず、textual にレンダリングして hermetic に検証する
# (テンプレート依存は {{ .chezmoi.homeDir }} と {{ .claude.permissions.allow | toJson }} のみ)。

load ../helpers/common

setup() {
  TMPL="$REPO_ROOT/home/dot_claude/settings.json.tmpl"
  HOOKS_DIR="$REPO_ROOT/home/dot_claude/hooks"
  RENDERED="$BATS_TEST_TMPDIR/settings.json"
  sed -e 's#{{ .chezmoi.homeDir }}#/HOME#g' \
    -e 's#{{ .claude.permissions.allow | toJson }}#[]#g' \
    "$TMPL" >"$RENDERED"
}

@test "rendered settings.json is valid JSON" {
  jq -e '.' "$RENDERED" >/dev/null
}

@test "every referenced hook command path exists as a hook source" {
  local cmd base missing=""
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] || continue
    base="$(basename "$cmd")"
    if [[ ! -f "$HOOKS_DIR/private_executable_$base" ]]; then
      missing+=" $base"
    fi
  done < <(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' "$RENDERED")
  if [[ -n "$missing" ]]; then
    echo "参照されているが実在しない hook:$missing"
    return 1
  fi
}

# ── context-pressure 系の登録契約 ──

@test "autoCompactEnabled is false" {
  jq -e '.autoCompactEnabled == false' "$RENDERED" >/dev/null
}

@test "PreCompact and PostCompact sections registered" {
  jq -e '.hooks.PreCompact[0].hooks | map(.command) | any(endswith("precompact-gate.sh"))' "$RENDERED" >/dev/null
  jq -e '.hooks.PostCompact[0].hooks | map(.command) | any(endswith("postcompact-marker.sh"))' "$RENDERED" >/dev/null
}

@test "UserPromptSubmit registers capture-transcript then notify" {
  # capture-transcript(turn++)が notify より先に走ること(同一イベント内の順序)
  local cmds
  cmds="$(jq -r '.hooks.UserPromptSubmit[].hooks[].command' "$RENDERED" | xargs -n1 basename | tr '\n' ' ')"
  case "$cmds" in
  *"capture-transcript.sh context-pressure-notify.sh"*) ;;
  *) echo "順序が不正: $cmds"; return 1 ;;
  esac
}

@test "gate registered on edit matchers but not on Bash" {
  jq -e '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit|NotebookEdit") |
    .hooks | map(.command) | any(endswith("context-pressure-gate.sh"))' "$RENDERED" >/dev/null
  # F-001: Bash に載せると compact-prep の脱出経路を塞ぐ
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") |
    .hooks | map(.command) | any(endswith("context-pressure-gate.sh"))' "$RENDERED"
  [ "$status" -ne 0 ]
}

@test "capture-plan-qa registered for ExitPlanMode and AskUserQuestion" {
  jq -e '.hooks.PostToolUse[] | select(.matcher == "ExitPlanMode|AskUserQuestion") |
    .hooks | map(.command) | any(endswith("capture-plan-qa.sh"))' "$RENDERED" >/dev/null
}
