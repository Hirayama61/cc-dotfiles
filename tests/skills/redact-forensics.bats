#!/usr/bin/env bats
# dev-pipeline forensics redaction の決定論的マスクと行数上限を固定する(SKILL §8 / V2 security）。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/home/dot_claude/skills/dev-pipeline/scripts/executable_redact-forensics.sh"
}

redact() { printf '%s' "$1" | bash "$SCRIPT" "${2:-0}"; }

@test "masks common token prefixes and keeps normal text" {
  out="$(redact 'ok line
key=sk-EXAMPLEONLYNOTAREALKEY00
gh=ghp_EXAMPLEONLYNOTAREALTOKENZZ
aws=AKIAIOSFODNN7EXAMPLE
plain sentence stays')"
  [[ "$out" == *"ok line"* ]]
  [[ "$out" == *"plain sentence stays"* ]]
  [[ "$out" != *"sk-EXAMPLEONLYNOTAREALKEY00"* ]]
  [[ "$out" != *"ghp_EXAMPLEONLYNOTAREALTOKENZZ"* ]]
  [[ "$out" != *"AKIAIOSFODNN7EXAMPLE"* ]]
  [[ "$out" == *"REDACTED"* ]]
}

@test "masks Bearer / Authorization token values" {
  out="$(redact 'Authorization: Bearer abcDEF123456ghijKLMN.opqRST_uvwx')"
  [[ "$out" != *"abcDEF123456ghijKLMN.opqRST_uvwx"* ]]
  [[ "$out" == *"REDACTED"* ]]
}

@test "masks long hex / base64 blobs" {
  out="$(redact 'hash=0123456789abcdef0123456789abcdef0123456789')"
  [[ "$out" != *"0123456789abcdef0123456789abcdef0123456789"* ]]
}

@test "line cap keeps only the last N lines with a marker" {
  in="$(printf 'L%s\n' $(seq 1 20))"
  out="$(printf '%s' "$in" | bash "$SCRIPT" 5)"
  [[ "$out" == *"末尾 5 行"* ]]
  [[ "$out" == *"L20"* ]]
  [[ "$out" != *"L14"* ]]
}

@test "masks KEY=value secrets (env dump, upper and lower)" {
  out="$(redact 'DB_PASSWORD=hunter2
API_SECRET=abc123
mysql_pwd=p@ssw0rd
NORMAL_VAR=keepme')"
  [[ "$out" != *"hunter2"* ]]
  [[ "$out" != *"abc123"* ]]
  [[ "$out" != *"p@ssw0rd"* ]]
  [[ "$out" == *"NORMAL_VAR=keepme"* ]]
}

@test "masks JWT and Basic auth credentials" {
  out="$(redact 'tok=eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.SflKxwRJSMeKKF2Q
Authorization: Basic dXNlcjpwYXNzd29yZA==')"
  [[ "$out" != *"eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.SflKxwRJSMeKKF2Q"* ]]
  [[ "$out" != *"dXNlcjpwYXNzd29yZA=="* ]]
}

@test "invalid max_lines falls back to safe default 500 (truncates >500, not unlimited)" {
  # 601 行を非数値 max_lines で渡す → 既定 500 に倒れ、先頭 101 行が落ちる(無制限でない)。
  in="$(printf 'L%s\n' $(seq 1 601))"
  run bash -c 'printf "%s\n" "$1" | bash "$2" not-a-number' _ "$in" "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"L601"* ]]
  [[ "$output" == *"末尾 500 行"* ]]
  [[ "$output" != *"L50 "* ]]
}

@test "masks bare (no-prefix) secret assignments and export form" {
  out="$(redact 'PASSWORD=hunter2
TOKEN=xyz789short
SECRET=s3cr3t
API_KEY=short1
export TOKEN=raw99deadbeef
NORMAL_VAR=keepme')"
  [[ "$out" != *"hunter2"* ]]
  [[ "$out" != *"xyz789short"* ]]
  [[ "$out" != *"s3cr3t"* ]]
  [[ "$out" != *"short1"* ]]
  [[ "$out" != *"raw99deadbeef"* ]]
  [[ "$out" == *"NORMAL_VAR=keepme"* ]]
}

@test "masks quoted secret value containing spaces (whole value)" {
  out="$(redact 'PASSWORD="alpha beta gamma"
keep=this')"
  [[ "$out" != *"alpha beta gamma"* ]]
  [[ "$out" != *"beta gamma"* ]]
  [[ "$out" == *"keep=this"* ]]
}

@test "masks single-quoted secret value containing spaces" {
  out="$(redact "PASSWORD='alpha beta gamma'
keep=this")"
  [[ "$out" != *"alpha beta gamma"* ]]
  [[ "$out" != *"beta gamma"* ]]
  [[ "$out" == *"keep=this"* ]]
}

@test "Authorization: Bearer <token> removes the token (not just the scheme)" {
  out="$(redact 'Authorization: Bearer myShortTok12abc')"
  [[ "$out" != *"myShortTok12abc"* ]]
  [[ "$out" == *"REDACTED"* ]]
}

@test "masks quoted JSON secret values" {
  out="$(redact '{"api_key": "sk-shortval", "note": "keep"}')"
  [[ "$out" != *"sk-shortval"* ]]
  [[ "$out" == *"keep"* ]]
}

@test "leading-zero max_lines does not octal-crash when truncating" {
  in="$(printf 'L%s\n' $(seq 1 12))"
  run bash -c 'printf "%s\n" "$1" | bash "$2" 08' _ "$in" "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"L12"* ]]
  [[ "$output" != *"L1 "* ]]
}

@test "no secrets in output for a mixed dump" {
  out="$(redact 'INFO starting
GITHUB_TOKEN=github_pat_EXAMPLEONLYNOTAREALTOKENZZ
xoxb-EXAMPLEONLYNOTAREALTOKENZZ
done')"
  [[ "$out" != *"github_pat_EXAMPLEONLYNOTAREALTOKENZZ"* ]]
  [[ "$out" != *"xoxb-EXAMPLEONLYNOTAREALTOKENZZ"* ]]
  [[ "$out" == *"INFO starting"* ]]
  [[ "$out" == *"done"* ]]
}
