---
name: tmux-claude-drive
description: >-
  tmux 越しに別の Claude Code セッション(別モデル・別権限モード)を起動し、
  指示投入→監視→検品まで運転する手順。「Opus に書かせて」「別セッションで実行して」
  「tmux でエージェントを回して」、`/tmux-claude-drive` での起動、あるいは別モデルの成果物を
  現セッションが検品するワークフローで発火する。2026-07-03 の小説プロジェクト(Fable 5 が
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
   **完了フレーズの照合は部分一致にしない** — 指示文自体に完了フレーズが含まれるため、
   pane に残る指示文のエコーを部分一致で拾うと即偽完了になる(2026-07-18 実測)。
   完了フレーズが**単独行**で出た時だけ完了とみなす(例: 該当行が鉤括弧
   『「」』などの指示文の引用符を含まないことも併せて確認する)。
4. 完了したら**現セッションが検品**する(成果物を通読し、規約・整合を突き合わせ、
   軽微な違反は直し、学びを規約文書に還元してからユーザーへ引き渡す)。
   検品後は**引き渡し報告を次の型で締める**(被運転が何を作り、こちらが何を直したかを
   運転者=人間に一目で見せる。無言で引き取らない):

   ```text
   ## 引き渡し — <タスク名>(被運転: <model>)
   成果物: <絶対パス>(複数なら列挙)
   検品所見: <規約・整合の突き合わせ結果を 1-2 文。合否と根拠>
   直した点: <こちらで直した軽微違反。無ければ「なし」>
   要判断: <人間の判断が要る残件。無ければ「なし」>
   ```
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

dev-pipeline 等がこの手順を運転部品として呼ぶ時、次の 4 点を運転元が決める。
いずれも既定は上の手順そのもの(小説 PJ 等の従来用途は無指定で変わらない)。

- **起動モデル**: 既定は `--model <model>` を明示。運転元が「指揮者のデフォルト
  モデルを継承させたい」場合は `--model` を**省略**して `claude` 単体で起動する
  (default model が再解決される)。
- **完了合図(nonce)**: 手順 2 の `<完了フレーズ>` は固定文字列だと偽完了を拾う。
  運転元が pipeline/phase ごとに一意な nonce(例 `DONE-<pipeline>-<phase>-<連番>`)を
  渡し、監視側はその nonce 一致でのみ完了とみなす。再利用しない。
- **完了後の window 処理**: 既定は手順 5 の `kill-window`。運転元が失敗 window を
  forensics 用に残したい場合は **retain**(kill せず capture-pane -S でログを吸い出し、
  赤ラベル相当のリネームで生かす)を選べる。
- **usage limit 検知時**: 既定は手順 3-(d) の「エラー通知して終了」。運転元が
  自動再開を持つ場合は、この検知を運転元の **rate-limit hook へ委譲**する
  (kill せず pane を生かし、別プロセスのタイマーに再開を任せる)。

これらは手順の**分岐点**であって別実装ではない。運転元は上の 1〜5 を踏襲し、
該当箇所だけ渡された値で振る舞いを変える。
