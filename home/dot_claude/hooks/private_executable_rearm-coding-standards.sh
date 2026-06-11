#!/usr/bin/env bash
# SessionStart(clear|compact): compaction / clear で規約がコンテキストから落ちうるため、
# inject-coding-standards.sh の既注入フラグを破棄し、次の編集で再注入させる。
# clear が transcript を引き継ぐ実装でも安全側に倒すため matcher に含めている。
# キー導出は flag-paths.sh(単一情報源)で inject 側と完全一致させる。
# lib 不達なら exit 0(inject 側も同時に常時注入へ倒れるため再注入漏れは起きない)。
set -euo pipefail

command -v jq &>/dev/null || exit 0
FLAG_LIB="$HOME/.claude/hooks/lib/flag-paths.sh"
[[ -r "$FLAG_LIB" ]] || exit 0
# shellcheck source=/dev/null
. "$FLAG_LIB"

input="$(cat || true)"
ctx="$(printf '%s' "$input" | jq -r '.transcript_path // .session_id // empty' 2>/dev/null || true)"
ctx="$(flag_ctx_key "$ctx" 2>/dev/null || true)"
[[ -z "$ctx" ]] && exit 0

rm -f "$(cs_injected_flag_prefix "$ctx")"* 2>/dev/null || true
exit 0
