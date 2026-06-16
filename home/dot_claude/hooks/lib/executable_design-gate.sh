#!/usr/bin/env bash
# design-gate.sh — 設計レビューゲート(Gate 1/2)の判定核の単一情報源(参謀ゲート Phase 4)。
#
# block-unreviewed-plan.sh(Gate 1: ExitPlanMode)と
# block-unreviewed-mutation.sh(Gate 2: 初回 mutation)が共有する:
#   - design_gate_exempt_dir … ゲート対象外ディレクトリの判定
#   - design_gate_pass       … フラグ評価 + pending 昇格 + branch への定着
#
# フラグ体系(キー導出は flag-paths.sh):
#   design-reviewed-<repo>--<branch>      … branch スコープ(セッション跨ぎの続き用。
#                                           commit では無効化しない)
#   design-reviewed-ctx-<repo>--<sid>     … セッションスコープ(plan 時点の branch 不在と
#                                           delegate の別 worktree ブランチをカバー。
#                                           sid は subagent と共有される)
#   design-reviewed-pending-<repo>        … 昇格用中間フラグ。モデル側は自分の session_id を
#                                           知れないため、skill が pending を書き、次の Gate
#                                           評価が自セッションの ctx 版へ取り込む
#   trivial-override-ctx-{,pending-}<repo>… Gate 2 専用の脱出口。**内容(理由)が非空である
#                                           ことを要求**する(空ファイルでの素通り防止 =
#                                           「理由必須・監査可能」の実装担保)
#
# 昇格の追加規則:
#   - sid が空なら昇格しない(空 sid キーへの mv で pending を浪費しない)
#   - 昇格先が symlink なら昇格しない(共有 /tmp への新規書込経路を増やさない。#49 系)
#   - pending には鮮度 TTL(未来 mtime も不正として弾く)
#   - ctx で通過した時、現在ブランチが非保護なら branch フラグへ**定着**させる
#     (main 上で Plan → feature ブランチで実装、のフローでセッションを跨いだ続きが
#      再ブロックされないように。design-scope-pending も同時に branch 版へ移す)
#
# 除外(ゲート対象外)= 判断②(Decisions: Phase4設計レビューゲートの3判断):
#   git repo 外 / ~/obsidian 配下(外部脳書込)/ repo root が /tmp・/private/tmp・
#   ~/.claude/jobs 配下(scratch 検証 repo)。コード repo だけを守る。
#
# 既知の受容: 同一マシン並行セッションの pending 取り込みレース / branch フラグの
# 恒久性(同名ブランチ切り直しで素通り)/ detached HEAD では branch フラグが効かない
# (ctx・pending が無ければブロックされるが、脱出口は trivial-override か再レビュー)。
# 自分の Claude を縛る best-effort ゲートであり敵対防御ではない。
#
# bash 3.2 互換・source 時に set 状態を汚染しない・fail-open(他 lib と同作法)。
# 依存: 呼び出し元が先に flag-paths.sh を source していること。is_protected_branch
# (resolve-base-ref.sh)があれば branch 定着に使う(無ければ定着だけ skip)。

# pending フラグの鮮度 TTL(秒)。
design_gate_pending_ttl() {
  printf '%s' "21600"
}

# dir がゲート対象外なら 0(素通し)、対象なら 1。
design_gate_exempt_dir() {
  local dir="${1:-}"
  [[ -z "$dir" ]] && return 0
  case "$dir" in
  "$HOME"/obsidian | "$HOME"/obsidian/*) return 0 ;;
  esac
  local root
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -z "$root" ]] && return 0
  root="$(cd "$root" 2>/dev/null && pwd -P || printf '%s' "$root")"
  case "$root" in
  /tmp | /tmp/* | /private/tmp | /private/tmp/* | "$HOME"/.claude/jobs | "$HOME"/.claude/jobs/*) return 0 ;;
  esac
  return 1
}

# フラグ読取は regular file のみ認める(-f/-s は symlink を辿るため、予測可能パスへの
# symlink 設置で読取側から解錠できてしまう。書込側の -L 拒否と対称の読取側硬化)。
_design_gate_flag_ok() { # path → 0 = 実在する regular file
  [[ -f "${1:-}" && ! -L "${1:-}" ]]
}

_design_gate_flag_nonempty() { # path → 0 = 非空の regular file
  [[ -s "${1:-}" && ! -L "${1:-}" ]]
}

_design_gate_fresh() { # file → 0 = TTL 内(未来 mtime は不正として弾く)
  local f="${1:-}" mt now
  mt="$(stat -f %m "$f" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  [[ "$mt" -le "$now" ]] || return 1
  [[ $((now - mt)) -le "$(design_gate_pending_ttl)" ]]
}

# pending を自セッションの ctx フラグへ昇格する。sid 空・昇格先 symlink は昇格しない
# (通過判定は呼び出し側が済ませている。昇格は次回評価の高速化であり必須ではない)。
_design_gate_promote() { # pending-path ctx-path sid
  local p="${1:-}" c="${2:-}" sid="${3:-}"
  [[ -z "$sid" ]] && return 0
  [[ -L "$c" ]] && return 0
  # state dir を確保してから mv(移行後の XDG dir は初回未作成)。確保失敗時は昇格を諦める
  # (return 0)。通過判定は呼び出し側で確定済みなので未昇格は次回再評価になるだけ=安全側。
  type claude_flag_dir_ensure >/dev/null 2>&1 && { claude_flag_dir_ensure || return 0; }
  mv "$p" "$c" 2>/dev/null || true
  return 0
}

# ctx / pending で通過した時、branch フラグへ定着させる(非保護ブランチのみ)。
# is_protected_branch(resolve-base-ref.sh)が無い環境では定着だけ skip(fail-open)。
_design_gate_solidify() { # repo branch
  local repo="${1:-}" branch="${2:-}"
  [[ -z "$repo" || -z "$branch" ]] && return 0
  type is_protected_branch >/dev/null 2>&1 || return 0
  is_protected_branch "$branch" && return 0
  # state dir を確保してから touch(移行後の XDG dir は初回未作成)。確保失敗時は定着を諦める
  # (return 0)。branch 定着は次回評価の高速化であって必須ではない=安全側。
  type claude_flag_dir_ensure >/dev/null 2>&1 && { claude_flag_dir_ensure || return 0; }
  local bf
  bf="$(design_reviewed_flag "$repo" "$branch")"
  [[ -L "$bf" ]] && return 0
  touch "$bf" 2>/dev/null || true
  # 宣言スコープも branch 版へ移す(Tier 3 が pending の 24h 失効・後勝ち上書きに
  # 依存しないように)。既に branch 版があれば触らない。
  local sp sb
  sp="$(design_scope_pending_flag "$repo")"
  sb="$(design_scope_flag "$repo" "$branch")"
  if _design_gate_flag_ok "$sp" && [[ ! -e "$sb" && ! -L "$sb" ]]; then
    mv "$sp" "$sb" 2>/dev/null || true
  fi
  return 0
}

# fresh pending があれば昇格して 0、無ければ 1。
_design_gate_try_pending() { # pending-path ctx-path sid
  local p="${1:-}"
  if _design_gate_flag_ok "$p" && _design_gate_fresh "$p"; then
    _design_gate_promote "$p" "${2:-}" "${3:-}"
    return 0
  fi
  return 1
}

# ゲート通過判定。0=通す / 1=ブロック。
#   design_gate_pass <repo> <sid> <branch> <allow_trivial(0|1)>
# allow_trivial=1 は Gate 2(trivial-override を脱出口に認める)。Gate 1 は 0
# (Plan を立てた時点で「軽微」ではないため override を認めない=計画仕様)。
design_gate_pass() {
  local repo="${1:-}" sid="${2:-}" branch="${3:-}" allow_trivial="${4:-0}"
  [[ -z "$repo" ]] && return 0

  if [[ -n "$branch" ]] && _design_gate_flag_ok "$(design_reviewed_flag "$repo" "$branch")"; then
    return 0
  fi
  if [[ -n "$sid" ]]; then
    if _design_gate_flag_ok "$(design_reviewed_ctx_flag "$repo" "$sid")"; then
      _design_gate_solidify "$repo" "$branch"
      return 0
    fi
    # trivial-override は理由(内容)非空を要求する。
    if [[ "$allow_trivial" == 1 ]] && _design_gate_flag_nonempty "$(trivial_override_ctx_flag "$repo" "$sid")"; then
      return 0
    fi
  fi

  if _design_gate_try_pending "$(design_reviewed_pending_flag "$repo")" \
    "$(design_reviewed_ctx_flag "$repo" "$sid")" "$sid"; then
    _design_gate_solidify "$repo" "$branch"
    return 0
  fi
  if [[ "$allow_trivial" == 1 ]]; then
    local tp
    tp="$(trivial_override_pending_flag "$repo")"
    if _design_gate_flag_nonempty "$tp" && _design_gate_fresh "$tp"; then
      _design_gate_promote "$tp" "$(trivial_override_ctx_flag "$repo" "$sid")" "$sid"
      return 0
    fi
  fi
  return 1
}
