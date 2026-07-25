#!/usr/bin/env bats
# block-secret-files.sh の E2E。秘密情報ファイルの読み込みを止め、通常ファイルを通すことを
# 固定する。判定は basename ベース(ディレクトリ位置に依存しない)。
#
# 遮断は exit 2 のみ。fail-open の判定は「exit != 2」(このリポの規約)。

load ../helpers/common

setup() {
  install_hooks
}

@test "blocks reading .env" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/.env"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading .env.production" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/.env.production"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading a pem key" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/certs/server.pem"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading a .key file" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/certs/server.key"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading a p12 bundle" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/certs/client.p12"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading an ssh private key" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.ssh/id_ed25519"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading credentials.json" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.config/gcloud/credentials.json"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading .netrc" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.netrc"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading a .token file" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/gh.token"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading a .secret file" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/db.secret"}}'
  [ "$status" -eq 2 ]
}

@test "allows reading a normal source file" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/src/main.sh"}}'
  [ "$status" -eq 0 ]
}

@test "allows reading env.example (not a dotfile env)" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/env.example"}}'
  [ "$status" -eq 0 ]
}

@test "allows reading a public key" {
  # 判定は完全一致(id_ed25519)なので .pub は対象外。
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.ssh/id_ed25519.pub"}}'
  [ "$status" -eq 0 ]
}

@test "allows a directory path whose parent is a secret-looking name" {
  # basename 判定なので、親ディレクトリ名に .env を含んでもファイル名が安全なら通す。
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/.env.d/README.md"}}'
  [ "$status" -eq 0 ]
}

@test "allows input without a file_path" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Bash","tool_input":{"command":"cat .env"}}'
  [ "$status" -eq 0 ]
}

@test "fails open without jq (exit != 2)" {
  local nojq
  nojq="$(make_no_jq_path)"
  run_hook_env "$nojq" block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/.env"}}'
  [ "$status" -ne 2 ]
}
