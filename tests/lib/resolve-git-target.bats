#!/usr/bin/env bats
# resolve-git-target.sh の字句解析・対象 dir 導出を固定する characterization テスト。
# quote-aware 判定・セグメント分割・cd/-C 畳み込みの現行挙動を固定する。

load ../helpers/common

setup() {
  install_hooks
  # shellcheck source=/dev/null
  source "$HOME/.claude/hooks/lib/resolve-git-target.sh"
}

# --- git_subcommand_of_segment ---
@test "subcommand: plain push" {
  run git_subcommand_of_segment "git push origin main"
  [ "$status" -eq 0 ]
  [ "$output" = "push" ]
}

@test "subcommand: quoted push (quote-aware)" {
  run git_subcommand_of_segment 'git "push" origin'
  [ "$status" -eq 0 ]
  [ "$output" = "push" ]
}

@test "subcommand: -C dir is skipped" {
  run git_subcommand_of_segment "git -C /work push"
  [ "$status" -eq 0 ]
  [ "$output" = "push" ]
}

@test "subcommand: merge-base is reported verbatim (not 'merge')" {
  run git_subcommand_of_segment "git merge-base a b"
  [ "$status" -eq 0 ]
  [ "$output" = "merge-base" ]
}

@test "subcommand: sudo prefix tolerated" {
  run git_subcommand_of_segment "sudo git commit -m x"
  [ "$status" -eq 0 ]
  [ "$output" = "commit" ]
}

# --- _git_c_dir_of_segment ---
@test "c-dir: extracts -C value" {
  run _git_c_dir_of_segment "git -C /work push"
  [ "$status" -eq 0 ]
  [ "$output" = "/work" ]
}

@test "c-dir: empty when no -C" {
  run _git_c_dir_of_segment "git push"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# --- segment_has_option (quote-aware) ---
@test "option: detects --no-verify long" {
  run segment_has_option "git commit --no-verify" --no-verify n
  [ "$status" -eq 0 ]
}

@test "option: detects bundled short -n in -anm" {
  run segment_has_option "git commit -anm x" "" n
  [ "$status" -eq 0 ]
}

@test "option: detects quoted --force" {
  run segment_has_option 'git push "--force"' --force f
  [ "$status" -eq 0 ]
}

@test "option: absent returns nonzero" {
  run segment_has_option "git commit -m x" --no-verify n
  [ "$status" -ne 0 ]
}

# --- split_git_segments ---
# split_git_segments は末尾で return 0 を明示し、入力に依らず戻り値を 0 に固定する
# (最終行が空でも while ループ末尾の `[[ -n "" ]] && printf` のショートサーキットで
# 1 を返さない。NEW-1 修正)。よって status 検証を行う。
@test "split: && separates into two segments" {
  run split_git_segments "cd /x && git push"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "cd /x" ]
  [ "${lines[1]}" = "git push" ]
}

@test "split: subshell parens are split points" {
  run split_git_segments "(cd /x && git push -f)"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "cd /x" ]
  [ "${lines[1]}" = "git push -f" ]
}

# --- resolve_git_target_dir ---
@test "target: -C nonexistent dir returns raw literal" {
  run resolve_git_target_dir "git -C /no/such/dir push" "/base"
  [ "$status" -eq 0 ]
  [ "$output" = "/no/such/dir" ]
}

@test "target: no explicit target falls back to cwd" {
  run resolve_git_target_dir "git push" "/base/cwd"
  [ "$status" -eq 0 ]
  [ "$output" = "/base/cwd" ]
}

@test "target: leading absolute cd is folded" {
  run resolve_git_target_dir "cd /no/such && git push" "/base"
  [ "$status" -eq 0 ]
  [ "$output" = "/no/such" ]
}

@test "target: leading relative cd is joined onto cwd (raw fallback; dirs absent)" {
  # /base も /base/sub も実在しないので _abs_dir(cd && pwd -P)が失敗し、_raw_dir の
  # リテラル連結(base + '/' + dir)へ落ちる経路を固定する。実在パスだと pwd -P で
  # 物理パス化され(macOS の /var→/private/var 等)値が変わるため、非実在を前提にする。
  run resolve_git_target_dir "cd sub && git push" "/base"
  [ "$status" -eq 0 ]
  [ "$output" = "/base/sub" ]
}

@test "target: -C wins over leading cd" {
  run resolve_git_target_dir "cd /other && git -C /no/such push" "/base"
  [ "$status" -eq 0 ]
  [ "$output" = "/no/such" ]
}

# --- strip_heredocs / strip_heredocs_lenient(D-38)---
# 復帰つき版は「遮断側パターンしか持たない hook 専用」。許可側パターン(early-exit /
# continue)をコマンド全文へ掛ける hook が使うと、復帰した本文が許可判定に当たって
# 遮断が消える。2 関数の契約差をここで固定する(実際に block-nested-worktree /
# block-defer-phrases の遮断を消しかけた)。

@test "strip_heredocs: closed heredoc body is dropped" {
  run strip_heredocs "$(printf 'cat <<EOF\nSECRETLINE\nEOF')"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'SECRETLINE'
}

@test "strip_heredocs: unterminated body stays dropped (strict)" {
  run strip_heredocs "$(printf 'echo "a << b"\nSECRETLINE')"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'SECRETLINE'
}

@test "strip_heredocs_lenient: unterminated body is restored" {
  run strip_heredocs_lenient "$(printf 'echo "a << b"\nSECRETLINE')"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'SECRETLINE'
}

@test "strip_heredocs_lenient: closed heredoc body is still dropped" {
  run strip_heredocs_lenient "$(printf 'cat <<EOF\nSECRETLINE\nEOF')"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'SECRETLINE'
}

@test "strip_heredocs_lenient: a closed body is not restored by a later false start" {
  run strip_heredocs_lenient "$(printf 'cat <<A\nCLOSEDBODY\nA\necho "x << y"')"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'CLOSEDBODY'
}

@test "strip_heredocs: hyphenated tag terminates correctly" {
  run strip_heredocs "$(printf 'cat <<END-OF\nSECRETLINE\nEND-OF\nTAILLINE')"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'SECRETLINE'
  echo "$output" | grep -qF 'TAILLINE'
}

@test "accepted gap: a false start whose tag reappears alone drops the lines between" {
  # 復帰は「終端タグ行が来ないまま EOF に達した」時だけ働く。誤認した開始のタグ語が
  # 後続行に単独で現れると偶発的に終端一致し、その間の行はバッファ破棄で消える。
  # タグは `EOF` に限らず `shift` / `done` のような実スクリプトに現れる語でも成立する。
  run strip_heredocs_lenient "$(printf 'echo "cat << EOF で書く"\nSECRETLINE\nEOF')"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'SECRETLINE'
}

@test "strip_heredocs_lenient: restored lines keep their original order" {
  run strip_heredocs_lenient "$(printf 'echo "a << b"\nLINE1\nLINE2\nLINE3')"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -nF LINE1 | cut -d: -f1)" -lt "$(echo "$output" | grep -nF LINE2 | cut -d: -f1)" ]
  [ "$(echo "$output" | grep -nF LINE2 | cut -d: -f1)" -lt "$(echo "$output" | grep -nF LINE3 | cut -d: -f1)" ]
}

# --- strip_heredocs_block_side(遮断側 hook 用の選択を lib に集約したもの)---

@test "strip_heredocs_block_side: prefers the lenient version (restores an unterminated body)" {
  run strip_heredocs_block_side "$(printf 'echo "a << b"\nSECRETLINE')"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'SECRETLINE'
}

@test "strip_heredocs_block_side: still drops a closed heredoc body" {
  run strip_heredocs_block_side "$(printf 'cat <<EOF\nSECRETLINE\nEOF')"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'SECRETLINE'
}

@test "strip_heredocs_block_side: falls back to the strict version when lenient is gone" {
  # apply 前後の版ずれで lib が旧版になる瞬間を模す。除去ゼロへ後退させない。
  unset -f strip_heredocs_lenient
  run strip_heredocs_block_side "$(printf 'cat <<EOF\nSECRETLINE\nEOF\nTAILLINE')"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'SECRETLINE'
  echo "$output" | grep -qF 'TAILLINE'
}

@test "strip_heredocs_block_side: returns the input unchanged when both are gone" {
  unset -f strip_heredocs_lenient strip_heredocs
  run strip_heredocs_block_side "$(printf 'cat <<EOF\nSECRETLINE\nEOF')"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'SECRETLINE'
}

# 復帰つきの入力は「遮断側パターンしか持たない hook」しか使ってはいけない。許可側パターンを
# コマンド全文へ掛ける hook(block-nested-worktree の `wt.sh` / block-defer-phrases の
# `(#NNN)`)がそれを受け取ると、復帰した本文が許可判定に当たって遮断が消える。
# 選択を lib へ集約したので、契約は次の 2 本で固定する:
#   (a) ラッパを呼ぶのは遮断側 2 hook だけ
#   (b) どの hook も復帰つき版を直接呼ばない(ラッパを迂回して契約を抜けられない)
# 2 本そろって初めて「復帰つきの入力を受け取るのは遮断側 2 hook だけ」が言える。
@test "contract: strip_heredocs_block_side is called only by block-side-only hooks" {
  local callers
  # コメント中の言及で落ちないよう、実際の呼び出し形(引数付き)だけを見る。
  callers="$(cd "$HOOKS_SRC" && grep -l 'strip_heredocs_block_side "' ./*.sh |
    sed -e 's|^\./private_executable_||' -e 's|^\./||' | sort | tr '\n' ' ')"
  [ "$callers" = "block-destructive-git.sh block-gh-mutations.sh " ]
}

@test "contract: no hook calls strip_heredocs_lenient directly" {
  local callers
  callers="$(cd "$HOOKS_SRC" && grep -l 'strip_heredocs_lenient "' ./*.sh | tr '\n' ' ')"
  [ -z "$callers" ]
}
