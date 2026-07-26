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

@test "blocks reading a pfx bundle" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/certs/client.pfx"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading an ssh private key" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.ssh/id_ed25519"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading an rsa private key" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.ssh/id_rsa"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading an ecdsa private key" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.ssh/id_ecdsa"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading a dsa private key" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.ssh/id_dsa"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading credentials.json" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.config/gcloud/credentials.json"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading an extensionless credentials file" {
  # ~/.aws/credentials は実在頻度が高く、拡張子が付かない形も完全一致で止める。
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.aws/credentials"}}'
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

@test "blocks reading a .secrets file" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/db.secrets"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading .env.example (intentional: .env.* glob is conservative)" {
  # `.env.*` グロブは中身を問わず止める。.env.example は秘密を含まないことが多いが、
  # 実際の秘密が入った .env.<環境名> と機械的に区別できないため安全側へ倒している。
  # これは意図的な挙動であり、緩めるなら人間の判断が要る(読みたい時は人間が ! で実行する)。
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/.env.example"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading .env.sample (same intentional glob)" {
  # .example だけを例外化する変更を検出できるよう、代表的な別名も固定する。
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/.env.sample"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading .envrc" {
  # direnv 経由で API トークンを export するのが典型。`.env.*` グロブには当たらない。
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/.envrc"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading .git-credentials" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.git-credentials"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading .npmrc" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/.npmrc"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading .pypirc" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.pypirc"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading .pgpass" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.pgpass"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading a jks keystore" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/release.jks"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading a .keystore file" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/app.keystore"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading service-account.json" {
  # 前方一致の `*` が空文字にも効く境界。実測で素通りしていた形そのもの。
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/service-account.json"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading a suffixed service account json" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/service-account-prod.json"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading a pem with an uppercase extension" {
  # 判定前に basename を小文字化するため、拡張子の大小に依存しない。
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/certs/private.PEM"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading a suffixed ssh private key" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.ssh/id_rsa.old"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading a dot-prefixed credentials.json" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.credentials.json"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading credentials.yml (known config extension)" {
  # credentials の射程は「完全一致 + 既知の設定拡張子」。ソース拡張子は通す(下の allows)。
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/config/credentials.yml"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading .env.pub" {
  # `.pub` 除外を id_* の内側へ閉じ込めた唯一の根拠。グローバル除外に平らにすると通ってしまう。
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/.env.pub"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading service_account.json (underscore variant)" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/service_account.json"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading a prefixed service account json" {
  # GCP コンソールのダウンロード名は <project>-service-account.json の形になる。
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/gcp-service-account.json"}}'
  [ "$status" -eq 2 ]
}

@test "blocks reading Rails credentials.yml.enc" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/config/credentials.yml.enc"}}'
  [ "$status" -eq 2 ]
}

@test "allows reading credentials.ts (an ordinary source file)" {
  # 前方一致にすると普通のソース名まで Read 遮断するため、既知の設定拡張子に限定している。
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/src/credentials.ts"}}'
  [ "$status" -eq 0 ]
}

@test "allows reading credentials.go (an ordinary source file)" {
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/internal/credentials.go"}}'
  [ "$status" -eq 0 ]
}

@test "accepted gap: a prefixed credentials name is not caught" {
  # credentials 側は前方一致にしない(ソース名の誤爆を避けるため)ので、
  # credentials_prod.json のような派生名は素通りする。受容済み。
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/credentials_prod.json"}}'
  [ "$status" -eq 0 ]
}

@test "allows reading an rsa public key" {
  # id_* は前方一致だが .pub は内側で明示除外している。
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.ssh/id_rsa.pub"}}'
  [ "$status" -eq 0 ]
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
  # id_* は前方一致に広げたが、その内側で .pub を明示除外しているため通る
  # (グローバルな早期 exit にすると credentials.pub 等まで通す抜け穴になる)。
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
  # 中立な payload を使う。Bash 経由の秘密読み出し(`cat .env` 等)は本 hook の対象外だが、
  # それをここで「通る」側に固定すると、将来 Bash 側を塞ぐ判断をした時に退行と読まれる。
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{}}'
  [ "$status" -eq 0 ]
}

@test "a leading-dash path still reaches the judgement (basename does not abort)" {
  # file_path は tool_input 由来の外部入力。`--` を付けないと basename がオプション誤認で
  # こけ、set -e で判定に到達しないまま hook が終わる(遮断が消える)。
  run_hook block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"-n/x/.env"}}'
  [ "$status" -eq 2 ]
}

@test "fails open without jq (exit != 2)" {
  local nojq
  nojq="$(make_no_jq_path)"
  run_hook_env "$nojq" block-secret-files.sh \
    '{"tool_name":"Read","tool_input":{"file_path":"/proj/.env"}}'
  [ "$status" -ne 2 ]
}
