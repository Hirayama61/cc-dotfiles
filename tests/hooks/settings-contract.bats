#!/usr/bin/env bats
# settings.json.tmpl の契約テスト。
# テンプレートのプレースホルダを差し替えて JSON として解釈し、hook 登録の不変条件を検証する:
#   - 詰まり検知(stuck-nudge.sh)が PostToolUseFailure(Bash) と PostToolUse(Bash) の両方に登録。
#   - 委譲ナッジ(delegation-nudge.sh)が PostToolUse の Grep|Glob を含む matcher に登録。
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

@test "stuck-nudge.sh is registered on PostToolUseFailure(Bash)" {
  jq -e '.hooks.PostToolUseFailure[]
    | select(.matcher == "Bash")
    | .hooks[] | select(.command | endswith("/stuck-nudge.sh"))' \
    "$RENDERED" >/dev/null
}

@test "stuck-nudge.sh is registered on PostToolUse(Bash) for reset" {
  jq -e '.hooks.PostToolUse[]
    | select(.matcher == "Bash")
    | .hooks[] | select(.command | endswith("/stuck-nudge.sh"))' \
    "$RENDERED" >/dev/null
}

@test "delegation-nudge.sh is registered on PostToolUse matcher covering Grep and Glob" {
  jq -e '.hooks.PostToolUse[]
    | select((.matcher | contains("Grep")) and (.matcher | contains("Glob")))
    | .hooks[] | select(.command | endswith("/delegation-nudge.sh"))' \
    "$RENDERED" >/dev/null
}

@test "delegation-nudge.sh matcher also covers Agent (for reset)" {
  jq -e '.hooks.PostToolUse[]
    | select(.hooks[]?.command | (. != null) and endswith("/delegation-nudge.sh"))
    | select(.matcher | contains("Agent"))' \
    "$RENDERED" >/dev/null
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
