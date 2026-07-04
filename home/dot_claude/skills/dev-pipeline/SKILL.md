---
name: dev-pipeline
description: >-
  開発フロー全体(設計 → 実装 → QA → PR 磨き)を、常駐する指揮者セッションが
  tmux 別 window 群の被運転セッションを運転して回すワークフロー。フェーズごとに
  コンテキスト・権限を分離し、人間の観測点を指揮者 1 箇所に固定する。「開発フロー
  全体を回して」「パイプラインで実装まで通して」「dev-pipeline で」で発火する。
  1 パイプライン = 1 ブランチ = tmux window 群、1 フェーズ = 1 window。
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Skill, Agent, AskUserQuestion, Monitor
---

# dev-pipeline — 開発フローを運転する

常駐の**指揮者セッション**(人間 + 上位モデル)が、開発フローの各フェーズを tmux 別
window の**被運転セッション**へ順に注入・監視・検品して回す。フェーズごとにコンテキストと
権限を分離し、人間の観測点は指揮者 1 箇所に固定する。運転の手つき(起動・literal 送信・
Monitor 監視・完了検知・後片付け)は **tmux-claude-drive skill を参照**し、再実装しない。

用語は `~/obsidian/brain/Tasks/cc-dotfiles/CONTEXT.md` の「開発パイプライン運転」節が正典。

## 1. 前提と安全原則(最初に必ず)

- **無人運転の明示許可を先に取る**。被運転を `--permission-mode acceptEdits` で無人起動する
  こと・承認ゲートを事前承認扱いにすることは、最初に AskUserQuestion で人間の許可を取ってから
  行う(auto mode classifier 対策。tmux-claude-drive の安全原則を継承)。
- **他セッションの権限プロンプトを代理承認しない**。被運転に権限プロンプトが出たら内容を
  要約して人間に押してもらう(send-keys で「1」を送らない = permission laundering 防止)。
- **被運転は再帰的な運転をしない**。被運転セッション内でさらに dev-pipeline / tmux 被運転を
  起動しない。ただし**被運転内部の通常の subagent 委譲(Task)は従来基準どおり行ってよい**
  (過剰な自粛をさせない)。
- **難所フェーズの effort 脱出口**: 既定は継承モデル・default effort の plain 起動。特定
  フェーズだけ上げたい時のみ `claude --effort <low|medium|high|xhigh|max>` を使う(既定運用では
  使わない)。

## 2. パイプライン定義の読み込みと信頼境界

対象リポの `.claude/dev-pipeline.toml` を読む。無ければ組込み既定
`reference/default-pipeline.toml`(FE repo 版: design → impl → qa → pr-polish)。schema は
その TOML 冒頭コメントが正典(`name` 必須、`[[phase]]` に `key`/`skill`/`gate`)。

**信頼境界**(project-local TOML は untrusted):

- **allowlist は soft**: 起動してよい skill 名・許可 phase key・`gate=auto` の可否は SKILL が
  持つ allowlist 内に限る。これは Claude が指示を守る model 実施の soft boundary。
- **hard 強制は既存ゲート + 人間承認**: design-reviewed / review-passed / 権限プロンプトは
  TOML に依らず既存 hook が hard 強制する。TOML はこれらを変更できない。
- **初回承認は内容ハッシュ単位**: per-repo TOML を初めて使う時、内容を人間へ提示して承認を取る。
  承認済み digest を repo キーと保存し、TOML が変わったら再承認(初回 1 回で固定しない)。

## 3. ブランチ/worktree 準備 → Phase 0(設計)を指揮者が直接実行

**先にブランチと worktree を作ってから設計に入る**(F-A: 1 パイプライン = 1 ブランチ共有、
設計もそのブランチで実行)。

1. **worktree を明示 base で作る**: 既定ブランチを解決し
   `~/ghq/github.com/Hirayama61/dotfiles/bin/wt.sh "<pipeline-branch>" "<base-ref>"` を
   **base-ref 明示**で呼ぶ(`wt.sh` の省略時 base は現在 HEAD であり既定ブランチではない。
   既存 feature worktree から起動して意図せぬ基点を掴まないため)。pipeline ブランチは
   **非保護 feature ブランチ**に限る(epic/main/develop 上では回さない — 保護ブランチだと
   design-reviewed の branch フラグが書かれない)。
2. **Phase 0 設計を指揮者が直接実行**(被運転化しない): この worktree を **cwd** にして
   grill-with-docs で設計し、design-review を回す。**design-review を feature worktree の cwd で
   実行する**のが要点 — branch フラグ(design-reviewed / design-scope)は
   `git branch --show-current` が非保護ブランチの時だけ feature ブランチキーで書かれる。main で
   走らせるとフラグが feature キーで書かれず、後続の被運転 impl が Gate 2 でブロックされる。
3. **stray pending の掃除**: design-review 完了・branch フラグ確定を確認したら、
   `design-reviewed-pending-<repo>`(branch 非依存)が残っていれば掃除する。これは並行
   パイプライン時に別ブランチの別セッションが取得して誤解錠しうるため(branch フラグは既に
   立っているので pending は不要)。掃除しても本ブランチのゲートは branch フラグで通る。

design-reviewed は repo+branch キーの branch フラグ(`flag-paths.sh`)なので、同一ブランチで
起動する被運転(独立 session_id)からも見える。ctx(session)フラグは同一 session_id 内でしか
伝播しないが、ブランチ共有でこれを回避する。

## 4. 各フェーズの運転(Phase 1 以降)

各フェーズ = 1 window = 1 合成 skill。運転手順は tmux-claude-drive を参照し、次を渡す:

1. **window を作る**: 名前は `<pipeline-id>-<phasekey>`(例 `authfix-impl`)。cwd は Phase 0 と
   同じ worktree(全フェーズが同一ブランチ・worktree を共有)。
2. **被運転を起動**: `claude --permission-mode acceptEdits`(`--model` 省略 = 指揮者の
   デフォルトモデルを継承。フェーズ単位のモデル/effort 判定はしない)。
3. **handoff doc を注入**: 被運転への literal 指示に、handoff doc のパスと「これだけ読んで当該
   フェーズの合成 skill(定義の `skill`)を回せ」「完了時に nonce『<pipeline>-<phase>-<連番>』
   だけ出して停止」を含める。
4. **Monitor で監視**(tmux-claude-drive 手順 3): 完了 nonce / 成果物出現 / 権限プロンプト /
   API Error・usage limit / pane 消失。usage limit を検知したら §6 経路 A のタイマーへ委譲する。
5. **検品**: 完了 nonce 一致を確認してから、指揮者が成果物を通読・規約整合を検品する。フェーズ内の
   修正(impl/qa/pr-polish の review 後の直し)は被運転自身が通常作業として行う(self-review 等は
   Edit/Write を持たないので修正は skill 外 = 被運転の本体作業)。

## 5. フェーズ遷移ゲート

検品通過後、パイプライン定義の `gate` で出し分ける。`human` なら検品結果を人間へ提示して承認待ち、
`auto` なら次フェーズへ。**未宣言は human**。`auto` の意味は「**遷移判断だけ無人**」で、次フェーズ
被運転の acceptEdits 起動承認・権限プロンプト応答は auto でも人間が行う。hard ゲート
(design-reviewed / review-passed)と権限プロンプトは gate 宣言に依らず常に人間。

## 6. 中断・再開(2 経路)

- **経路 A(レートリミット)**: 被運転プロセスは生存する前提。`scripts/rate-limit-resume.sh
  <window-target>` を起動する(素のシェルで Claude のレートリミットを消費しない)。banner が
  明けたら再開フレーズを 1 度送り、指揮者は Monitor でその出力(`RLR: sent` / `resumed` /
  `route-b …`)を回収する。`route-b` が出たら経路 B へ切り替える(スクリプト自身は遷移しない)。
- **経路 B(セッション死亡: kill / API Error / 検品 NG)**: handoff doc(状態真実源)+ git 作業木
  (worktree の変更済みファイル)から指揮者が進捗を復元し、新しい被運転へ「ここまで済み」を注入して
  当該フェーズ頭から再開する。worktree 隔離により実差分は残る。

## 7. handoff doc(状態真実源)

- **命名**: `~/obsidian/brain/Tasks/<repo>/<pipeline-id>-handoff.md`(1 パイプライン 1 ファイル)。
  `<pipeline-id>` は filesystem-safe ID(branch 名の `/` 等を変換。表示名とは別に持つ)。
- **frontmatter**: `pipeline` / `repo` / `branch` / `worktree` / `created` / `updated`。
- **書込所有権 = 指揮者単一 writer**: handoff を書き換えるのは指揮者のみ。被運転は成果物ファイル +
  pane 上の完了 nonce で signal し、指揮者が検品してから当該フェーズの status を更新する
  (複数 writer の lost update を構造的に排除。一時ファイル + mv は部分書込しか防げない)。
- **原子的更新**: 書換は temp を **同一ディレクトリ**(`Tasks/<repo>/`)に作って mv(同一 FS の
  原子的 rename)。
- **フェーズ状態機械**: 各フェーズ `key` に `status` ∈ {pending, running, review, done, failed}、
  `executor`(conductor|driven)、`nonce`、`terminal_status` ∈ {done, failed, aborted}。
  許可遷移: `pending → running → review → done`、任意時点から `failed`。検品 NG は `review →
  failed`、経路 B 復元は `failed → running`(指揮者が新セッション注入時)。rate-limit 中は status を
  変えない(running のまま。forensics に記録)。
- **nonce**: pipeline+phase ごとに指揮者が起動時に一意採番(例 `<pipeline>-<phase>-<連番>`)。
  被運転が完了時に出力し、指揮者が一致を検証して初めて done。再利用しない。
- **Phase 0 の非対称吸収**: 設計フェーズも同一 schema で表す(`key=design, executor=conductor`)。

## 8. 後片付け / Window 管理

- 検品済み window は畳む(kill)。
- **失敗時**(API Error / usage limit / 検品 NG)は window を kill せず生かす。`capture-pane -S`
  でスクロールバックを handoff の forensics 欄へ吸い出す。**行数上限 + redaction**(トークン等の
  秘匿)を掛け、**全文は別ログパス**へ、handoff には要約を書く。証跡がファイルに残るのでセッション
  終了でも失われない。

## 9. config キー ↔ window 名の対応

| config `key` | window 名 | 内容 |
|---|---|---|
| design | (window 非生成) | grill-with-docs → design-review(指揮者直接、Phase 0) |
| impl | `<pipeline-id>-impl` | 実装 → self-review → 修正 |
| qa | `<pipeline-id>-qa` | fe-qa → バグレポート → 修正 |
| pr-polish | `<pipeline-id>-pr-polish` | PR 作成 → push 直前 self-review → push |

## 10. worktree ライフサイクル

- **作成元 ref を明示**(§3-1)。命名は 1 パイプライン = 1 ブランチ = 1 worktree で一貫。
- **phase 間共有**: 全フェーズが同一 worktree/ブランチを共有(F-A)。被運転は `-c <worktree>` で
  その dir に起動する。
- **削除後処理**: PR マージ後、指揮者が dirty / 未 push commit を確認 → 残存 window を kill →
  handoff を done で確定(Tasks/ に残す)→ worktree 削除。中断中(経路 B 復元待ち)は残す。
  design-reviewed の branch フラグは worktree 削除で消えず同名 branch 再作成で再利用されうる
  (既知の best-effort。気になれば手で消す)。
