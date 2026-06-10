#!/usr/bin/env bash
# SessionStart(clear|compact): compaction / clear で規約がコンテキストから落ちうるため、
# inject-coding-standards.sh の既注入フラグを破棄し、次の編集で再注入させる。
# clear が transcript を引き継ぐ実装でも安全側に倒すため matcher に含めている。
# キー導出は inject 側と完全一致させること(transcript_path 基準・.jsonl 除去)。
set -euo pipefail

command -v jq &>/dev/null || exit 0
input="$(cat || true)"
ctx="$(printf '%s' "$input" | jq -r '.transcript_path // .session_id // empty' 2>/dev/null || true)"
ctx="$(basename "${ctx%.jsonl}" 2>/dev/null || true)"
[[ -z "$ctx" ]] && exit 0

rm -f "/tmp/claude-sessions/cs-injected-${ctx}--"* 2>/dev/null || true
exit 0
