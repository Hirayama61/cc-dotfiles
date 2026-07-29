#!/usr/bin/env bash
# PreToolUse(Bash): 未コミット作業を復元不能に破棄しうる git 操作をブロックする(dotfiles#72)。
# 対象: reset --hard / clean -f系 / stash drop・clear / branch 強制削除(-D とその等価形)/
#       restore(worktree 接触)/ checkout の変更破棄(-- / pathspec / -f)/ switch の変更破棄
#       (--discard-changes とその別名 --force / -f)/ worktree remove --force。
# delegate 規約緩和(二段階の自己分類化)の補償として、客観条件を hook 層で担保する。
# 既存 block 系と同じ best-effort 字句検査(難読化は対象外)。人間は ! バイパスで実行可能。
# 対象範囲は「未コミット作業の破棄」に限る。ブランチ先端の付け替え(switch -C / checkout -B)は
# コミット済みの ref を壊す別分類なので見ない(branch -D を止めるのとは非対称)。
# 既知の限界(受容): long オプションの前方略記(--ha 等)・バックスラッシュ行継続は検出しない。
# 既知の限界(受容・D-41): checkout の pathspec は ref 名として不正な形だけを見る
# (先頭 `.` / `/` / `~`、末尾 `/`、`*`、`?`)。ref 名としても妥当な形は pathspec と区別
# できないため通す(`git checkout src/main.sh` の 1 引数形も、`git checkout HEAD src/main.sh`
# の tree-ish + pathspec 形も。後者は語数で判別できるが、オプションの引数個数
# (`-b feat/x main`)を解析することになり whack-a-mole になる)。次も対象外:
# `[...]` のグロブ、pathspec magic(`:!` / `:(`。`:/text` は正当なリビジョン指定なので
# `:` を一律には見られない)、`--pathspec-from-file`、`git checkout -p`(対話的な hunk 破棄)。
# 既知の限界(受容): heredoc を stdin として実行する形(`bash <<EOF` / `cat <<EOF | bash` /
# `ssh h <<EOF`)の本文は実行されるコマンドだが、strip_heredocs はデータと区別せず落とす。
# 安全側設計: jq 無し / 空コマンド / lib 不在なら exit 0(通す)。
set -euo pipefail

LIB="$HOME/.claude/hooks/lib/hook-input.sh"
[[ -r "$LIB" ]] || exit 0
# shellcheck source=/dev/null
( . "$LIB" ) >/dev/null 2>&1 || exit 0
. "$LIB" 2>/dev/null || exit 0
hook_init || exit 0
cmd="$(hook_command)"; [[ -z "$cmd" ]] && exit 0

source_hook_lib resolve-git-target.sh || exit 0

# heredoc 本文を除去して誤爆を防ぐ(dotfiles#74)。除去は正しく閉じた heredoc に限り、
# 終端タグが見つからない形(クォート内の `<< 語`・算術シフト・未終端)は本文が復帰して
# 照合対象に残る(過剰遮断側。D-38)。どの版を使うかの選択は lib が単一情報源。
# ラッパごと無い旧 lib のときだけ厳格版へ、それも無ければ除去を省く。
cmd="$(strip_heredocs_block_side "$cmd" 2>/dev/null || strip_heredocs "$cmd" 2>/dev/null || printf '%s' "$cmd")"

block() {
  echo "ブロック: $1 は未コミット作業や stash を復元不能に破棄しうるため禁止。人間が判断し、必要なら Claude Code のプロンプトで !<コマンド> として実行すること(Bash 引数の先頭に ! を付けても同じくブロックされる)。" >&2
  exit 2
}

while IFS= read -r seg; do
  [[ -z "$seg" ]] && continue
  case "$(git_subcommand_of_segment "$seg")" in
  reset)
    segment_has_option "$seg" --hard && block "git reset --hard"
    ;;
  clean)
    # 実削除に必須の -f / --force だけを見る。-n/--dry-run 併用(clean -nf 等)は
    # 削除しないため許可する。
    if ! segment_has_option "$seg" --dry-run n && segment_has_option "$seg" --force f; then
      block "git clean -f"
    fi
    ;;
  stash)
    norm="$(normalized_words_of_segment "$seg")"
    if printf '%s' "$norm" | grep -qE '(^|[[:space:]])stash[[:space:]]+(drop|clear)([[:space:]]|$)'; then
      block "git stash drop/clear"
    fi
    ;;
  branch)
    # -d(merged 限定の安全削除)は許可。強制削除(-D とその等価形 -df / --delete --force)のみ止める。
    segment_has_option "$seg" "" D && block "git branch -D"
    if segment_has_option "$seg" --delete d && segment_has_option "$seg" --force f; then
      block "git branch --delete --force"
    fi
    ;;
  restore)
    # --staged 単独(index のみ・worktree 非接触)は許可。それ以外は worktree の
    # 未コミット変更を破棄しうるため止める(-W/--worktree 明示を含む)。
    if segment_has_option "$seg" --worktree W || ! segment_has_option "$seg" --staged S; then
      block "git restore(worktree の変更破棄)"
    fi
    ;;
  checkout)
    # ブランチ切替・-b は許可。パス指定の変更破棄(-- / pathspec)と -f/--force を止める。
    norm="$(normalized_words_of_segment "$seg")"
    if printf '%s' " $norm " | grep -qE '[[:space:]]--[[:space:]]'; then
      block "git checkout -- <path>(変更破棄)"
    fi
    # ref 名は先頭の `.` / `/` / `~`、グロブ文字を許さない(git check-ref-format)。この形の
    # 引数は pathspec 確定なので、`--` が無くても worktree の変更破棄になる。
    # 走査は `checkout` より後ろに限る。前置グローバルオプションの引数(`git -C /abs/path`)を
    # 巻き込むと、ただのブランチ切替が止まる。リダイレクト先(`> /dev/null`)も引数ではないので
    # 飛ばす。リダイレクトは任意位置に置けるため、打ち切らず後続の走査を続ける。
    if [[ "$norm" == *" checkout "* ]]; then
      read -r -a cargs <<<"${norm#* checkout }"
      skip_next=0
      for w in ${cargs[@]+"${cargs[@]}"}; do
        if [ "$skip_next" -eq 1 ]; then
          skip_next=0
          continue
        fi
        case "$w" in
        '#'*) break ;;
        '>' | '>>' | '<' | '<>' | [0-9]'>' | [0-9]'>>' | [0-9]'<' | [0-9]'<>')
          skip_next=1
          continue
          ;;
        '>'* | '<'* | [0-9]'>'*) continue ;;
        -*) continue ;;
        .* | /* | '~'* | */ | *'*'* | *'?'*) block "git checkout <path>(変更破棄)" ;;
        esac
      done
    fi
    segment_has_option "$seg" --force f && block "git checkout -f"
    ;;
  switch)
    # --discard-changes(別名 --force / -f)は checkout -f と同義で未コミット変更を破棄する。
    if segment_has_option "$seg" --discard-changes f || segment_has_option "$seg" --force ""; then
      block "git switch --discard-changes / -f"
    fi
    ;;
  worktree)
    norm="$(normalized_words_of_segment "$seg")"
    if printf '%s' "$norm" | grep -qE '(^|[[:space:]])worktree[[:space:]]+remove([[:space:]]|$)'; then
      segment_has_option "$seg" --force f && block "git worktree remove --force(dirty worktree の破棄)"
    fi
    ;;
  esac
done < <(split_git_segments "$cmd")

exit 0
