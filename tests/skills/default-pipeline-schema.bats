#!/usr/bin/env bats
# default-pipeline.toml の schema 契約テスト(Plan v2 §2.4 / §7.7 = V2-S-09)。
#
# TOML は grep/sed で判定しない(重複 key・型違反・見せかけ key を誤判定するため)。
# 実 TOML parser(python tomllib/tomli)がある環境でのみ検証し、無ければ skip する
# (parser を独断で toolchain へ足さない。untrusted な per-repo TOML の実行時対策は
# skill の信頼境界=allowlist soft + hard gate + 人間承認が担う)。

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
  TOML="$REPO_ROOT/home/dot_claude/skills/dev-pipeline/reference/default-pipeline.toml"
}

# 実 TOML parser で TOML を JSON へ。無ければ空文字(呼び出し側で skip 判定)。
toml_to_json() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import sys, json
try:
    import tomllib as t
except ModuleNotFoundError:
    try:
        import tomli as t
    except ModuleNotFoundError:
        sys.exit(3)
with open(sys.argv[1], "rb") as f:
    print(json.dumps(t.load(f)))
PY
}

have_parser() {
  python3 - <<'PY' 2>/dev/null
import sys
try:
    import tomllib  # noqa
except ModuleNotFoundError:
    try:
        import tomli  # noqa
    except ModuleNotFoundError:
        sys.exit(1)
PY
}

@test "default-pipeline.toml parses and satisfies schema" {
  if ! have_parser; then
    skip "TOML parser(python tomllib/tomli)未導入 — 実 parser 環境で検証する"
  fi
  json="$(toml_to_json "$TOML")"
  [ -n "$json" ]
  run python3 - "$json" <<'PY'
import sys, json
d = json.loads(sys.argv[1])
assert isinstance(d.get("name"), str) and d["name"], "name 必須(非空文字列)"
phases = d.get("phase")
assert isinstance(phases, list) and phases, "[[phase]] が非空配列"
valid_keys = {"design", "impl", "qa", "pr-polish"}
valid_gates = {"human", "auto"}
seen = []
for p in phases:
    k = p.get("key")
    assert k in valid_keys, f"未知 key: {k}"
    assert isinstance(p.get("skill"), str) and p["skill"], f"{k}: skill 必須"
    assert p.get("gate", "human") in valid_gates, f"{k}: gate は human|auto"
    seen.append(k)
assert seen[0] == "design", "先頭 phase は design(Phase 0 予約)"
assert len(seen) == len(set(seen)), "key の重複なし"
PY
  [ "$status" -eq 0 ]
}
