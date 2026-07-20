---
name: tmux-claude-drive
description: >-
  tmux 越しに別の Claude Code セッション(別モデル・別権限モード)を起動し、
  指示投入→監視→検品まで運転する手順。「Opus に書かせて」「別セッションで実行して」
  「tmux でエージェントを回して」、あるいは別モデルの成果物を現セッションが
  検品するワークフローで発火する。2026-07-03 の小説プロジェクト(Fable 5 が
  Opus 4.8 に第4話を書かせ検品)で確立。dev-pipeline はこれを運転部品として参照する。
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, AskUserQuestion
---

# tmux-claude-drive — 別セッションの Claude Code を運転する

現セッション(運転者)が tmux の別ウィンドウに Claude Code(被運転者)を起動し、
タスクを自律実行させ、成果物を検品して引き取る。

## 前提と安全原則(最初に必ず)

1. **被運転者は permission-mode 指定なしで起動する**。settings の
   `permissions.defaultMode: "auto"` が被運転セッションにも効くため、編集許可は
   auto mode に任せる。`--permission-mode acceptEdits` は明示しない(auto mode
   classifier に阻まれる経路であり、defaultMode=auto の環境では不要。毎回の
   AskUserQuestion 確認もしない)。defaultMode を**超える**権限
   (bypassPermissions 等)を使いたい時だけ、事前に AskUserQuestion で確認する。
2. **他セッションの権限プロンプトを代理承認しない**(send-keys で「1」を送るのは
   classifier がブロックする=permission laundering 防止)。プロンプトが出たら内容を
   要約してユーザーに押してもらう。頻発するなら、対象リポの settings に読み取り専用
   Bash の許可ルールを足す提案をする(勝手に足さない)。

## 手順

1. `tmux ls` でセッションを確認し、新ウィンドウで起動する:
   `tmux new-window -t <session>: -n <name> -c <workdir> -d`
   `tmux send-keys -t <session>:<name> 'claude --model <model>' Enter`
   (permission-mode は指定しない。前提 1 のとおり defaultMode=auto に任せる)
   数秒待って `tmux capture-pane -t ... -p | tail` で起動を確認(モデル名は Claude の pane 内
   ステータス行に出る。tmux の status bar ではなく pane 本文なので capture-pane -p で読める)。
   **権限モードも同時に確認する** — 直近出力(`tail` 範囲)の**現在のステータス行**に
   「⏵⏵ auto mode on」が出ていることを確認する(scrollback の古い表示や別文脈の部分一致を
   合格にしない)。この完全一致が取れない場合 — 別モード(bypassPermissions / 格下げ含む)・
   表示欠落・部分一致のみ — は送信せず停止してユーザーに報告する。前提 1 の例外として
   **明示承認済みの上位モードで起動した場合**は、その承認済みモードの表示を確認対象にする
   (auto の完全一致で false stop させない)。
2. 指示は **1行の literal 送信**(改行は送信になる): `tmux send-keys -t ... -l '<指示文>'`
   → `sleep 1` → `tmux send-keys -t ... Enter`。指示文には次を含める:
   - 従うワークフロー/skill 名と、承認ゲートの扱い(**何が許可済みかの範囲を区別して明記する**:
     許可済みなのはこの依頼・タスク自体で、被運転側の hard ゲート(push/設計レビュー等)や
     権限プロンプトは事前承認済みにならない)
   - 対話不能環境での分岐処理(推奨案を自己選択し理由をファイルに記録)
   - 完了時の合図: 「最後に『<完了フレーズ>』とだけ書いて停止すること」
3. **Monitor で監視**(sleep ポーリング禁止・完了/停止/失敗の全終端を拾う):
   45〜60 秒間隔で `tmux capture-pane -p | tail -25` を見て、
   (a) 完了フレーズ → 終了、(b) 成果物ファイルの出現 → 通知のみ、
   (c) `Do you want to proceed|❯ 1\. Yes` → 権限プロンプト(ユーザーへ)、
   (d) `API Error|usage limit` → エラー通知、(e) pane 消失 → 終了。
   フラグ変数で同一イベントの重複発報を抑止する。
4. 完了したら**現セッションが検品**する(成果物を通読し、規約・整合を突き合わせ、
   軽微な違反は直し、学びを規約文書に還元してからユーザーへ引き渡す)。
5. **後片付け**: `tmux kill-window -t <session>:<name>`。被運転セッションに
   /loop や cron の残骸があると勝手に再稼働するため、放置しない。

## 落とし穴(実測)

- `codex exec` は非 git ディレクトリでは `--skip-git-repo-check` が必須
  (無いと "Not inside a trusted directory" で無言失敗する)。
- capture-pane は描画済みテキストのみ。長い出力は `-S -<行数>` で遡る。
- 被運転者の作業中にこちらから同一ファイルを編集すると Edit の staleness 競合が起きる。
  検品前に必ず Read し直す。
- 指示文に引用符を含める時は send-keys `-l` を使い、シェルのクォート衝突を避ける。

## fail-open

- tmux が無い/セッションが無い環境では、この手順を諦めて `claude -p`(headless)への
  切り替えを提案する(対話ゲートが要るタスクには不向きと明示する)。
- Monitor ツールが使えない場合は Bash `run_in_background` の until ループで
  完了フレーズ検知のみに簡略化する。

## パラメータ(運転元スキル向け・省略で従来挙動)

dev-pipeline / task-fleet 等がこの手順を運転部品として呼ぶ時、次の 5 点を運転元が決める。
いずれも既定は上の手順そのもの(小説 PJ 等の従来用途は無指定で変わらない)。

- **起動モデル**: 既定は `--model <model>` を明示。運転元が「指揮者のデフォルト
  モデルを継承させたい」場合は `--model` を**省略**して `claude` 単体で起動する
  (default model が再解決される)。
- **完了合図(nonce)**: 手順 2 の `<完了フレーズ>` は固定文字列だと偽完了を拾う。
  運転元が pipeline/phase ごとに一意な nonce(例 `DONE-<pipeline>-<phase>-<連番>`)を
  渡し、監視側はその nonce 一致でのみ完了とみなす。再利用しない。
- **起動先ターゲット(window / pane split)**: 既定は手順 1 の `tmux new-window`
  (1 セッション = 1 window に被運転 1 つ)。運転元が同一 window 内へ複数被運転を並べたい
  場合は **pane split** を選べる。この時 pane は生成 id を決定論的に取る形で作り
  (`pane_id="$(tmux split-window -d -P -F '#{pane_id}' -t <session>:<window> -c "$workdir")"`。
  `-d` で管理 pane からフォーカスを奪わない、`-P -F '#{pane_id}'` で新 pane id を直接受ける。
  後付けの display-message で「どれが新 pane か」を当てない=誤 pane 送信の穴を塞ぐ。split は
  pane 最小高を割ると失敗して空を返すので、生成直後に `%NN` 形かを検査して空なら中止する)、以後の
  **send-keys / capture-pane / Monitor / 後片付け(kill)を、window 名でなくこの `pane_id`
  (`%NN`)に固定する**。rate-limit-resume.sh は pane 指定(`session:window.pane` or `%pane_id`)を
  受け起動時に `%pane_id` へ固定するので整合する。
- **完了後の window/pane 処理**: 既定は手順 5 の `kill-window`。**pane split で起動した被運転は
  window でなく `kill-pane <pane_id>` で畳む**(同一 window に管理 pane や兄弟 pane が同居する
  ため、window ごと kill すると巻き添えで自壊する)。失敗した window/pane を forensics 用に
  残したい場合は **retain** を選べる。retain が残すのは**スクロールバックだけ**で、順序は
  (1) `capture-pane -J -p -S -2000 -t <pane_id>` でログを取り、
  `<skills>/dev-pipeline/scripts/redact-forensics.sh` を通して 0600 のファイルへ書き出す →
  (2) 赤ラベル相当のリネームで失敗マークを付ける → (3) 被運転プロセスを終了させる、に固定する。
  redaction は必ずこの canonical スクリプトを使い、独自の実装で代替しない。
  **capture とリネームを終了より先に済ませる** — pane のコマンドとして直接 `claude` を起動した
  場合、その終了で pane ごと消えてスクロールバックもリネーム対象も失われる(既定は
  `remain-on-exit` off)。シェル経由で起動していれば pane は残るが、順序を固定しておけば
  どちらの起動方法でも安全側になる。`kill-pane` はログ吸い出し後の「畳む」操作としてのみ使う。
  **被運転プロセスを生かしたまま残さない** — auto mode のセッションが放置されると、後から別作業で
  誤って入力・再開される(task-fleet §10 と同一の契約)。
- **usage limit 検知時**: 既定は手順 3-(d) の「エラー通知して終了」。運転元が
  自動再開を持つ場合は、この検知を運転元の **rate-limit hook へ委譲**する
  (kill せず pane を生かし、別プロセスのタイマーに再開を任せる)。並列 pane を同一アカウントで
  走らせる運転元は、共有レートリミット下の一斉再開(thundering-herd)を避ける責務も持つ。
  対策は**同時稼働本数を絞ること**(リミット中は稼働 pane を減らし、明けたら順に再投入する)。
  **「再開の時間差化」を単独の対策として当てにしない** — `rate-limit-resume.sh` の送信時刻は
  banner から算出した deadline で決まるため、タイマーの起動時刻をずらしても送信は banner 消失から
  1 ポーリング間隔以内に固まる(task-fleet §9 と同一の契約)。

これらは手順の**分岐点**であって別実装ではない。運転元は上の 1〜5 を踏襲し、
該当箇所だけ渡された値で振る舞いを変える。
