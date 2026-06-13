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
