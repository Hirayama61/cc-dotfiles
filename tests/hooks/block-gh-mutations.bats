#!/usr/bin/env bats
# block-gh-mutations.sh の E2E。外向き/不可逆な gh サブコマンド(pr の
# ready/merge/close/reopen・release の create/delete/edit/upload・repo の
# delete/archive/edit)を止め、read-only な gh と対象外(gh api)を通すことを固定する。
#
# 遮断は exit 2 のみ。fail-open の判定は「exit != 2」(このリポの規約)。
# pr / release / repo は独立した3分岐で、status だけでは「別分岐が発火した」型の退行を
# 検知できないため、各分岐の代表テストでブロックメッセージも突き合わせる。

load ../helpers/common

setup() {
  install_hooks
}

@test "blocks gh pr merge" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 123 --squash"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'gh pr の'
}

@test "blocks gh pr ready" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr ready 123"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr close" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr close 123"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr reopen" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr reopen 123"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr merge behind a global flag with a value" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh -R owner/repo pr merge 1"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr merge behind a --flag=value" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh --repo=owner/repo pr merge 1"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr merge behind an env assignment" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"PAGER=cat gh pr merge 1"}}'
  [ "$status" -eq 2 ]
}

@test "blocks a quoted merge subcommand" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr \"merge\" 1"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr merge after a command separator" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr view 1 && gh pr merge 1"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh release create" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh release create v1.0.0"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'gh release の'
}

@test "blocks gh release delete" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh release delete v1.0.0"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh release edit" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh release edit v1.0.0 --draft=false"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'gh release の'
}

@test "blocks gh release upload" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh release upload v1.0.0 dist/app.zip"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'gh release の'
}

@test "blocks gh repo delete" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh repo delete owner/repo"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'gh repo の'
}

@test "blocks gh repo archive" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh repo archive owner/repo"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh repo edit" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh repo edit --visibility private"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'gh repo の'
}

@test "blocks gh pr merge on the second line of a multi-line command" {
  # D-36: 判定は行ごとに行う。以前は normalized_words_of_segment をコマンド全体へ適用して
  # おり、read が1行目で止まるため2行目以降が照合対象から丸ごと消えていた。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git status\ngh pr merge 1"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr merge inside a newline-formed for loop" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"for n in 1 2\ndo\n  gh pr merge $n\ndone"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr merge inside a one-line for loop" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"for n in 1 2; do gh pr merge $n; done"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr merge behind time" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"time gh pr merge 1"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr merge inside a brace group" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"{ gh pr merge 1; }"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr merge as an if condition" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"if gh pr merge 1; then echo ok; fi"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr merge as a negated if condition" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"if ! gh pr merge 1; then echo ng; fi"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr merge as a while condition" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"while gh pr merge 1; do echo x; done"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr merge with an env prefix on a later line" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"echo start\nGH_TOKEN=x gh pr merge 1"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr merge with an env assignment before a shell keyword" {
  # 前置語と env 代入は順不同で書ける。片方を先にしか許さないと `GH_TOKEN=x time gh ...` が抜ける。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"GH_TOKEN=x time gh pr merge 1"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh pr merge with two env assignments before a shell keyword" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"A=1 B=2 time gh pr merge 1"}}'
  [ "$status" -eq 2 ]
}

@test "blocks a gh mutation on the heredoc opening line itself" {
  # strip_heredocs は本文だけを落とし開始行は残す。この境界が崩れると、heredoc を付けた
  # だけで遮断が消える(既存テストは全て緑のまま検出だけ失われる)ため 1 本で固定する。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 1 <<EOF\nnote\nEOF"}}'
  [ "$status" -eq 2 ]
}

@test "blocks gh repo delete on the second line of a multi-line command" {
  # 複数行分割 + PRE は 3 ルールが個別に文字列補間されている。pr だけ検証すると
  # release / repo 側の書き間違いを検知できないので、別ルールもメッセージまで見る。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"echo start\ntime gh repo delete owner/repo"}}'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'gh repo の'
}

@test "allows read-only gh pr commands" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr view 123 --json state"}}'
  [ "$status" -eq 0 ]
}

@test "allows gh pr list" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr list --limit 10"}}'
  [ "$status" -eq 0 ]
}

@test "allows gh pr create" {
  # PR 作成は外向きだが対象外(ready/merge/close/reopen のみが不可逆な状態変更)。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr create --fill"}}'
  [ "$status" -eq 0 ]
}

@test "allows gh release view" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh release view v1.0.0"}}'
  [ "$status" -eq 0 ]
}

@test "allows gh repo view" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh repo view owner/repo"}}'
  [ "$status" -eq 0 ]
}

@test "accepted gap: gh api is out of scope" {
  # gh api は read-only な GET を多く含み誤検知が多いため意図的に非対象(hook ヘッダ)。
  # `accepted gap:` 接頭辞は「hook が守れていないと合意済みの穴」の機械的な目印。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh api -X DELETE repos/owner/repo/issues/1"}}'
  [ "$status" -eq 0 ]
}

@test "no false positive: gh pr merge mentioned mid-command is allowed" {
  # BORDER が「コマンド開始位置の gh」に限定するため、引数中の言及では発火しない。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"echo run gh pr merge later >> notes.txt"}}'
  [ "$status" -eq 0 ]
}

@test "allows a gh mutation mentioned in a heredoc body" {
  # 判定を行ごとに変えた副作用で heredoc 本文が照合対象に入るため、strip_heredocs を
  # 前置して打ち消している。PR 本文やコメント本文を heredoc で書くのは日常的。
  # 正しく閉じた heredoc に限る — 終端が見つからない形は本文が復帰する(D-38)。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"cat <<EOF > notes.txt\ngh pr merge 1\nEOF"}}'
  [ "$status" -eq 0 ]
}

@test "allows a closed heredoc body even when a later line starts a false heredoc" {
  # 終端タグ行でバッファを破棄しないと、後続の偽 heredoc 開始で EOF 復帰が走ったときに
  # 「既に正しく閉じた本文」まで一緒に復帰して誤爆する。その境界を固定する。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"cat <<A\ngh pr merge 1\nA\necho \"x << y\""}}'
  [ "$status" -eq 0 ]
}

@test "allows a gh mutation mentioned in a quoted-tag heredoc body" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr comment 1 --body-file - <<'"'"'BODY'"'"'\ngh pr merge 1 は人間が実行する\nBODY"}}'
  [ "$status" -eq 0 ]
}

@test "allows a gh mutation mentioned on a later line of an echo" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"echo hi\necho run gh pr merge later"}}'
  [ "$status" -eq 0 ]
}

@test "allows a read-only gh behind time (PRE does not widen the subcommand set)" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"time gh pr view 1"}}'
  [ "$status" -eq 0 ]
}

@test "allows a read-only gh as an if condition" {
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"if gh pr view 1; then echo ok; fi"}}'
  [ "$status" -eq 0 ]
}

@test "accepted overblock: a PRE keyword inside a same-line string literal blocks" {
  # `accepted gap:` の鏡像。gap は「守れていない穴」(検出漏れ)、overblock は
  # 「意図した過剰遮断」(止めすぎ)を指す。どちらも合意済みの受容を機械的に拾える印。
  # ここは `;` が BORDER に、続く then が PRE に当たるため文字列リテラル内でも一致する。
  # クォート内かの判別には本物のシェル字句解析が要り、字句 grep 型 hook の設計方針に反する。
  # 向きが過剰遮断側で `!` プレフィックスの回復手段があるため受容する。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"echo \"step1; then gh pr merge later\""}}'
  [ "$status" -eq 2 ]
}

@test "accepted overblock: a real newline inside a quoted argument blocks" {
  # 判定を行ごとに変えた代償。2行目が行頭 gh になるため一致する。
  # 診断可能性の限界: 打ったのは git commit なのに gh の話をするメッセージが出る。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"line1\ngh pr merge 1\""}}'
  [ "$status" -eq 2 ]
}

@test "accepted gap: a heredoc executed as stdin is not inspected" {
  # `bash <<EOF` の本文は実行されるコマンドだが、strip_heredocs はデータと区別せず落とす。
  # 開始行のコマンド種別を見て落とさない実装は可能だが、この PR の射程外(D-40 で起票)。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"bash <<EOF\ngh pr merge 1\nEOF"}}'
  [ "$status" -eq 0 ]
}

@test "accepted gap: a backslash line continuation splits the command" {
  # 改行で行分割するため 2 片に割れる。block-destructive-git.sh の header が既に同じ
  # 限界を受容している。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr \\\n  merge 1"}}'
  [ "$status" -eq 0 ]
}

@test "accepted gap: backtick command substitution is not caught" {
  # `$(...)` は BORDER の `(` に当たり捕捉されるが、バッククォートは境界文字に無い。
  # hook ヘッダが既に受容と明記している経路。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"x=`gh pr merge 1`"}}'
  [ "$status" -eq 0 ]
}

@test "accepted gap: an env wrapper is not caught" {
  # PRE のキーワードは列挙であり、列挙外の前置語は素通りする。ラッパー系はそれぞれ独自フラグを
  # 取るため字句照合が whack-a-mole になる。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"env gh pr merge 1"}}'
  [ "$status" -eq 0 ]
}

@test "accepted gap: a case branch body is not caught" {
  # `)` は BORDER に含まれない。git 側(split_git_segments が `)` を切る)とは非対称。
  # BORDER に `)` を足すと閉じるが、`(...)` を含む注記文まで巻き込むため見送った。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"case x in a) gh pr merge 1 ;; esac"}}'
  [ "$status" -eq 0 ]
}

@test "accepted gap: a shell function definition is not caught" {
  # 定義時点では実行されない。上の case 分岐本体と同じく、BORDER に `)` を足す案の
  # 採否がひっくり返った時にちょうど動く境界なので証跡として置く。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"f(){ gh pr merge 1; }"}}'
  [ "$status" -eq 0 ]
}

@test "blocks a gh mutation after a false heredoc start in a quoted string" {
  # strip_heredocs は `<<`+語 をクォート内でも heredoc 開始と誤認するが、終端タグ行が
  # 来ないまま EOF に達したら捨てた行を出し直すので、以降の行は照合対象に残る(D-38)。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"echo \"see a << b\"\ngh pr merge 1"}}'
  [ "$status" -eq 2 ]
}

@test "blocks a gh mutation after an arithmetic left shift" {
  # `$((1<<b))` も `<<`+語 に当たる。終端は来ないので同じく復帰する。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"n=$((1<<b))\ngh pr merge 1"}}'
  [ "$status" -eq 2 ]
}

@test "allows a gh mutation mentioned in a hyphenated-tag heredoc body" {
  # タグ捕捉にハイフンを含めるので `<<END-OF` も正しく終端でき、本文は除去される。
  # ここを狭めると、シェル的に正しく閉じた heredoc の本文が未終端扱いで復帰し誤爆する。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"cat <<END-OF\ngh pr merge 1\nEND-OF"}}'
  [ "$status" -eq 0 ]
}

@test "blocks a gh mutation after a closed hyphenated-tag heredoc" {
  # 本文は除去されるが、heredoc の外に出た後の行は照合対象に残る。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"cat <<END-OF\nbody\nEND-OF\ngh pr merge 1"}}'
  [ "$status" -eq 2 ]
}

@test "blocks a gh mutation inside a genuinely unterminated heredoc" {
  # 終端タグが来ない形は本文が復帰する(D-38 の保護。過剰遮断側へ倒す)。
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"cat <<EOF\ngh pr merge 1"}}'
  [ "$status" -eq 2 ]
}

@test "guarded source: corrupt resolve-git-target lib fails open (exit != 2)" {
  echo "{ broken bash (" >"$HOME/.claude/hooks/lib/resolve-git-target.sh"
  run_hook block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 1"}}'
  [ "$status" -ne 2 ]
}

@test "fails open without jq (exit != 2)" {
  local nojq
  nojq="$(make_no_jq_path)"
  run_hook_env "$nojq" block-gh-mutations.sh \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 1"}}'
  [ "$status" -ne 2 ]
}
