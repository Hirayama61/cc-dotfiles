---
name: task-fleet
description: >-
  1 つの管理セッションが案件を並列タスクへ分割し、tmux pane 群の被運転セッションを
  同時運転する運転ワークフロー。実作業を被運転へ逃がして管理セッションを軽く保ち、
  人間の相談役を兼ねる。「タスクを並列で回して」「艦隊で流して」「案件を分割して
  同時に走らせて」「task-fleet で」で発火する。dev-pipeline(フェーズ直列)の姉妹で、
  タスク並列 + 相談役型。1 案件 = 1 window(pane 分割)、1 pane = 1 branch = 1 worktree。
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Skill, Agent, AskUserQuestion, Monitor
---

# task-fleet — 案件を並列タスクへ分割して艦隊運転する

1 つの**管理セッション**(人間 + モデル)が、案件を並列化可能なタスクへ分割し、同一
案件 window 内の tmux pane 群へ**被運転セッション**を起動して同時に回す。実作業は被運転へ
逃がして管理セッションのコンテキストを軽く保ち、管理セッションは人間の相談役を兼ねる。
運転の手つき(起動・literal 送信・Monitor 監視・完了検知・後片付け)は **tmux-claude-drive
skill を参照**し、再実装しない。dev-pipeline(フェーズ直列)の姉妹で、こちらはタスク並列。

用語は `~/obsidian/brain/Tasks/cc-dotfiles/CONTEXT.md` の「タスク艦隊運転(area:
task-fleet)」節が正典。状態真実源・レートリミット再開・forensics redaction は
**dev-pipeline のスクリプトを流用**する(新規スクリプトは作らない。dev-pipeline の
`scripts/rate-limit-resume.sh` / `scripts/redact-forensics.sh` を展開後パスで呼ぶ。
将来は共有 dir への抽出候補)。

## 1. 前提と安全原則(最初に必ず)

- **被運転は permission-mode 指定なしで起動する**(tmux-claude-drive 前提 1 を継承)。
  settings の `defaultMode: "auto"` が被運転にも効くため編集許可は auto mode に任せ、
  毎回の AskUserQuestion 確認はしない。defaultMode を**超える**権限(bypassPermissions 等)を
  使いたい時だけ、事前に AskUserQuestion で人間の許可を取る。
- **被運転モデルは `--model opus` を明示する**(Decisions #6。dev-pipeline の「継承」とは
  逆の選択)。管理セッション自身のモデルは固定しない(Fable 5 でも Opus 4.8 でもよい)。
- **他セッションの権限プロンプトを代理承認しない**。被運転に権限プロンプトが出たら内容を
  要約 + 推奨案を添えて人間に押してもらう(send-keys で「1」を送らない = permission
  laundering 防止)。これは**代理応答境界**の一方の壁で、緩めない。
- **代理応答境界の内容質問側**: 被運転からの内容質問は、承認済み分割計画の範囲内で確信が
  あれば管理セッションが直接代理応答して並列を止めない。計画外・不確実・影響大は推奨案を
  添えて人間へ上げる(権限プロンプトは上記のとおり常に人間で、この代理応答の対象外)。
- **被運転は再帰的な運転をしない**。被運転セッション内でさらに task-fleet / dev-pipeline /
  tmux 被運転を起動しない。被運転内部の通常の subagent 委譲(Task)は従来基準どおり行ってよい。

## 2. 分割計画と「一度承認 → 自動連鎖」

管理セッションが案件を並列化可能な単位へ分割し、次を含めた**分割計画**を人間へ提示する
(薄いタスクリストにしない):

- タスク間の依存関係と実行順(並列可能な束と、直列に待つ束を区別する)。
- 後続タスク(レビュー / QA / 統合)をタスクとして計画に含める。
- **相互依存タスクを並列化する時は、境界インターフェース契約を分割時に確定**し、依存する
  双方のタスク指示書へ同じ契約文を書く(後から片方だけ変えない)。

人間が分割計画を**一度承認**したら、以降のタスク投入は**自動連鎖**する — タスク完了検知で
後続タスク pane を人間承認なしに投入してよい(根拠は分割計画の一度の承認)。ただし
**hard ゲート(権限プロンプト・push・design-review)は従来どおり常に人間**。計画外の事態
(想定しない依存の発覚・契約の破れ・影響大の判断)が出たら**連鎖を止めて人間へ相談**として
上げる(自動連鎖は「分割承認まで無人」ではない)。

## 3. 案件 window と pane 構成

- **1 案件 = 1 tmux window**。中を**管理セッション pane + タスク pane 群**に分割する
  (相談役が隣で同時に見えること自体が価値のため pane 分割を採る)。
- **1 pane = 1 branch = 1 worktree**(既存規約)。複数タスク並列の案件は epic ブランチを
  派生させ、`~/ghq/github.com/Hirayama61/dotfiles/bin/wt.sh "<task-branch>" "<base-ref>"` で
  タスク別 worktree を base-ref 明示で作る(単一タスクの案件は feature 1 本でよい)。
  タスクブランチは**非保護 feature ブランチ**に限る(§4 のフラグが書かれる条件)。
- **pane 上限 = 既定 3**(管理 pane を除く。狭 pane 化の抑制)。上限は管理セッション判断で
  調整可能(既定 3 は出発点)。
- **spillover window(pane 上限超過時)**: 上限超過分は**同一案件の副 window**
  (window 名 `<fleet-id>-w2` 等)へ逃がす。**案件単位は 1 window を基本とし、超過時のみ副
  window を派生する**(CONTEXT.md「1 案件 = 1 window」を保ちつつ、超過は例外的に副 window で
  受ける)。副 window は管理 pane を持たないので、管理セッションは §7 の Monitor で主 window の
  タスク pane と副 window の被運転を pane 別状態でまとめて監視する。

## 4. Gate 2 との噛み合わせ(フラグ展開)

案件設計は着手前に **design-review に一度通す**(この skill を回す前提)。分割計画の人間承認
時に、管理セッションが計画に**列挙された各タスクブランチ**へ design-reviewed の branch フラグを
展開する(**フラグ展開**。案件設計が design-review を一度通っている効力の継承であって素通し
ではない。ツール改修は不要)。手順は design-review skill と同じ安全作法を必ず踏む:

```sh
# repo キーは resolve-repo-key.sh 由来(手組みしない)。実行は対象 worktree の cwd で。
repo="$("$HOME/.claude/hooks/lib/resolve-repo-key.sh" "$PWD" 2>/dev/null || true)"
[ -n "$repo" ] || { echo "repo key が引けない。中断" >&2; exit 1; }
# state dir 検証を必ず前置(未作成 dir への touch は silent fail しうる)。
"$HOME/.claude/hooks/lib/flag-paths.sh" dir-ensure \
  || { echo "flag state dir の検証に失敗。中断" >&2; exit 1; }
# 計画に列挙された各タスクブランチにのみ展開する。
for branch in "${task_branches[@]}"; do
  # 保護ブランチには branch フラグを書かない(epic 派生案件では epic/* が周辺に常在する)。
  case "$branch" in
  "" | main | master | develop | epic/*) continue ;;
  esac
  touch "$("$HOME/.claude/hooks/lib/flag-paths.sh" design-reviewed "$repo" "$branch")"
done
```

- **CLI はパスを print するだけ**(`flag-paths.sh design-reviewed <repo> <branch>`)。生成は
  上記の `touch "$(...)"` 形にする。branch のハッシュサフィックス化は CLI 内 `flag_safe_branch`
  が担うので raw branch 名を渡す。
- **計画外ブランチへは展開しない**。1 件の誤展開が Gate 2 の誤解除になる(展開対象は分割計画に
  列挙した branch に限る)。
- **design-scope は fan-out で展開しない**。design-review skill は branch フラグと対で
  design-scope(Tier 3 スコープ宣言)を書くが、fan-out は Gate 2(mutation)解除の
  `design-reviewed` のみ立てる。スコープ乖離チェックが効くのは push 時で、push は常に人間の
  hard ゲートのため実害は限定的。各タスクブランチのスコープはタスク指示書の成果物宣言で担保する。

## 5. 各タスクの運転

各タスク = 1 pane(または spillover 副 window の 1 pane)= 1 被運転セッション。運転手順は
tmux-claude-drive を参照し、次を渡す:

1. **pane を作る(起動先ターゲット = pane split)**: 管理 pane のある案件 window を split し、
   生成 pane id を決定論的に受け取る:
   `pane_id="$(tmux split-window -d -P -F '#{pane_id}' -t <session>:<window> -c <task-worktree>)"`
   (`-d` でフォーカスを管理 pane から奪わない、`-P -F '#{pane_id}'` で新 pane の id を直接取る。
   後付けの display-message で「どれが新 pane か」を当てない = 誤 pane 送信の穴を塞ぐ)。以後の
   send-keys / capture-pane / Monitor / 後片付けは、この `pane_id`(`%NN`)を対象に固定する。
2. **被運転を起動**: `claude --model opus`(permission-mode 指定なし = defaultMode=auto)。
   起動確認時に pane の auto mode 表示も確認する(tmux-claude-drive 手順 1)。
3. **補間値のサニタイズ(必須)**: 被運転へ literal 送信する値(fleet-id・taskkey・nonce・
   handoff パス・**タスク間インターフェース契約**)は、送る前に**単一行・制御文字なし**を保証し、
   fleet-id / taskkey / nonce は `[A-Za-z0-9._-]` へ正規化する(dev-pipeline §4-3 継承。改行混入は
   send-keys `-l` の途中確定=premature submit + クロスセッション注入経路になる)。ファイル名用の
   ID と人間向け表示名は別に持つ。
4. **指示を注入**: literal 指示に、タスク指示書 / handoff doc のパスと「これだけ読んで担当タスクを
   実行せよ」「完了時に nonce を完了ファイル `Tasks/<repo>/.done-<fleet>-<taskkey>` に書いて停止」を
   含める。承認範囲の区別(**許可済みなのはこのタスク自体で、被運転側の hard ゲート=push/設計
   レビュー等・権限プロンプトは事前承認にならない**)、対話不能分岐での推奨案自己選択 + 理由記録も
   含める(tmux-claude-drive 手順 2)。
5. **Monitor で監視**(§7 の pane 別状態で束ねる)。完了検知は pane 本文でなく完了ファイルの出現 +
   nonce 一致で行う(入力=pane / 出力=ファイルの分離)。

## 6. 検品(レポート駆動 + 最終検品)

- **タスク単位はレポート駆動検品**: 管理セッションは成果物全文を読まず、被運転が書く**完了
  レポート**(やったこと・判断・懸念・成果物パス)と、後続レビュー / QA タスクの結果だけを読む。
  これがコンテキスト最適化の中心機構。
- **案件の締めに最終検品**: 案件の全タスクが done になったら、管理セッションがタスク全体の
  成果物を通したチェック(タスク間の契約整合・全体の一貫性)を別途行う。

## 7. 状態真実源(handoff doc)と並列 Monitor

dev-pipeline §7 のパターンを**タスク単位へ読み替えて流用**する(直列フェーズ → 並列タスク)。

- **命名**: `~/obsidian/brain/Tasks/<repo>/<fleet-id>-handoff.md`(1 案件 1 ファイル)。
  `<fleet-id>` は filesystem-safe ID(branch 名の `/` 等を変換。表示名とは別に持つ)。
- **書込所有権 = 管理セッション単一 writer**: handoff を書き換えるのは管理セッションのみ。被運転は
  成果物ファイル + 完了ファイルの nonce で signal し、管理セッションが検品してから当該タスクの
  status を更新する(複数 writer の lost update を構造的に排除)。
- **原子的更新**: 書換は temp を**同一ディレクトリ**(`Tasks/<repo>/`)に作って mv。
- **タスク状態機械(schema)**: 各タスク `key` に次を持つ。
  - `status` ∈ {pending, running, review, done, failed}、`executor` ∈ {manager, driven}、
    `terminal_status` ∈ {done, failed, aborted}。
  - `branch` / `worktree` / `pane_id`(`%NN`)/ `window`(主 or `<fleet-id>-w2`)/ `nonce`。
  - `depends_on`(依存タスク key)/ `blocks`(後続タスク key)/ `interface`(契約の要点 or 参照)。
  - `report_path`(完了レポート)/ `forensics_log`(失敗時のログパス)。
  - 許可遷移: `pending → running → review → done`、任意時点から `failed`。検品 NG は
    `review → failed`、経路 B 復元は `failed → running`。rate-limit 中は status を変えない
    (running のまま。forensics に記録)。
- **nonce と完了検知**: fleet+task ごとに管理セッションが起動時に一意採番(再利用しない)。完了
  検知は pane 本文 grep でなく専用完了ファイル `Tasks/<repo>/.done-<fleet>-<taskkey>` の出現 +
  中身の nonce 一致で行う(指示エコーの自己反射誤検知を避ける)。
- **並列 Monitor の pane 別状態**: tmux-claude-drive 手順 3 の Monitor は単一 pane 前提なので、
  task-fleet は**どの pane が 完了 / usage limit / 権限プロンプト / API Error / pane 消失か**を
  pane 別に持つ状態で、主 window のタスク pane 群 + spillover 副 window をまとめて監視する。
  同一 pane の同一イベントの重複発報はフラグで抑止する。

## 8. 統合(タスクブランチ → epic)

- タスクブランチ → epic ブランチの merge は**管理セッションが検品後に実施**する。
- **merge 前の機械的最低検品**(レポート駆動検品を崩さず、merge の事故面だけ下げる): 完了 nonce の
  一致・`git status`(dirty / 未 commit の確認)・タスクブランチの diff 要約・テスト結果・完了
  レポートが指す成果物 path の存在確認。これらは全文通読ではない機械的チェックとして必ず通す。
- **軽微なコンフリクトは管理セッションが直接解決**してよい。ただし解決のための epic worktree 上の
  編集は**保護 epic ブランチ上で Gate 2(mutation)に当たる**(epic は保護ブランチで branch フラグを
  持てない)。解錠は (a) 人間承認の理由付き trivial-override、または (b) 後述の被運転投入経路
  (非保護 worktree で解決)へ寄せる。長尺案件では管理セッションの `design-reviewed-pending` が
  TTL 失効しうるため、締めの手編集を当てにせず被運転経路を既定に置くのが安全。
- **重いコンフリクトは統合タスクとして被運転へ**投入する(1 統合タスク = epic を base にした非保護
  worktree で解決させ、レポート駆動検品する)。

## 9. 中断・再開(2 経路)

- **経路 A(レートリミット)**: 被運転プロセスは生存する前提。pane ごとに
  `<skills>/dev-pipeline/scripts/rate-limit-resume.sh <pane_id>` を起動する(素のシェルで
  Claude のレートリミットを消費しない)。banner が明けたら再開フレーズを 1 度送り、管理セッションは
  Monitor でその出力(`RLR: sent` / `resumed` / `route-b …`)を回収する。`route-b` が出たら経路 B へ。
  - **共有レートリミットの thundering-herd 対策**: 並列タスク pane は**同一アカウントの 1 つの
    レートリミットを共有**する(dev-pipeline は直列でこの問題に当たらない)。usage limit は全 pane に
    ほぼ同時到達し、明けた瞬間に N 本の再開が一斉送信 → 直後に再度リミット、を起こしうる。pane ごとに
    タイマー(別 `RLR_SIGNAL_FILE`)を持たせつつ、**再開を時間差化**するか**同時稼働本数を絞る**
    (例: リミット中は稼働 pane を減らし、明けたら順に再投入する)。一斉再開はしない。
- **経路 B(セッション死亡: kill / API Error / 検品 NG)**: handoff doc(状態真実源)+ その
  タスクの worktree の変更済みファイルから管理セッションが進捗を復元し、新しい被運転へ「ここまで
  済み」を注入して当該タスク頭から再開する(worktree 隔離により実差分は残る)。

## 10. 後片付け / forensics

- **検品済み pane は `kill-pane` で閉じる**(`kill-window` は使わない — 案件 window には管理 pane と
  兄弟タスク pane が同居するため、window ごと kill すると自分の観測点と並列作業を巻き込んで自壊する)。
  spillover 副 window は、その中の被運転を全て畳んだら window ごと kill してよい。
- **失敗 pane は kill せず残す**(forensics)。`capture-pane -J -p -S -2000 -t <pane_id>` で
  スクロールバックを取り、**書き出す前に必ず `<skills>/dev-pipeline/scripts/redact-forensics.sh`
  を通す**(認証途中の値・環境変数ダンプの決定論的マスク。`-J` は折り返しトークンの取りこぼし
  防止に必須)。書き出し先ログは **0600・非共有 dir**(`Tasks/<repo>/` 配下)に置き
  (`install -m 600 /dev/null <log>` で先に作る)、handoff の `forensics_log` に参照を書く
  (全文平文を handoff 本体に残さない)。手作業で消さない。

## 11. fail-open

- tmux が無い / セッションが無い環境では、この手順を諦めて `claude -p`(headless)への切替を
  提案する(並列運転と対話ゲートには不向きと明示)。
- Monitor が使えない場合は Bash `run_in_background` の until ループで完了ファイル検知のみに
  簡略化する(tmux-claude-drive の fail-open を継承)。
