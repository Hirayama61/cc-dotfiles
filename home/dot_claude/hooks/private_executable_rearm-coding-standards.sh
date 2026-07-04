#!/usr/bin/env bash
# SessionStart(clear|compact): compaction / clear で規約がコンテキストから落ちうるため、
# inject-coding-standards.sh の既注入フラグを破棄し、次の編集で再注入させる。
# clear が transcript を引き継ぐ実装でも安全側に倒すため matcher に含めている。
# キー導出は flag-paths.sh(単一情報源)で inject 側と完全一致させる。
# lib 不達なら exit 0(inject 側も同時に常時注入へ倒れるため再注入漏れは起きない)。
set -euo pipefail

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$LIB" ) >/dev/null 2>&1 || exit 0
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0
source_hook_lib flag-paths.sh || exit 0

ctx="$(hook_field '.transcript_path // .session_id')"
ctx="$(flag_ctx_key "$ctx" 2>/dev/null || true)"
[[ -z "$ctx" ]] && exit 0

rm -f "$(cs_injected_flag_prefix "$ctx")"* 2>/dev/null || true
# capture-decision.sh の 1 ctx 1 回フラグも同時に再武装する(clear|compact 後の新しい
# 文脈では判断記録ナッジをもう一度許す)。版ずれ(旧 flag-paths.sh)は無視。
if type decision_nudged_flag >/dev/null 2>&1; then
  rm -f "$(decision_nudged_flag "$ctx")" 2>/dev/null || true
fi
# stuck-nudge.sh の種別ごとカウント dir と 1 ctx 1 回 claim を破棄する
# (clear|compact 後の新しい文脈では詰まり検知をやり直す)。版ずれは無視。
if type stuck_count_dir_prefix >/dev/null 2>&1; then
  rm -rf "$(stuck_count_dir_prefix "$ctx")"* 2>/dev/null || true
  rm -rf "$(stuck_nudged_flag "$ctx")" 2>/dev/null || true
fi
# delegation-nudge.sh の探索累計カウント dir と claim も同時に再武装する。版ずれは無視。
if type delegation_count_dir >/dev/null 2>&1; then
  rm -rf "$(delegation_count_dir "$ctx")" 2>/dev/null || true
  rm -rf "$(delegation_nudged_flag "$ctx")" 2>/dev/null || true
fi
exit 0
