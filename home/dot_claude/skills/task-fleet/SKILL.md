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
- **送信前の権限プロンプト検知は機械的に行う**(モデルの目視判断に依存しない)。管理セッションが
  pane へ何かを送る前(代理応答・自動連鎖投入・再開フレーズのいずれも)に、`capture-pane` の末尾を
  `<skills>/dev-pipeline/scripts/rate-limit-resume.sh` が持つ `PERMISSION_ERE` と同じ正規表現で
  照合し、**一致したら送らずに人間へ上げる**。送信判定が否定形(「権限プロンプトでなければ送る」)で
  ある以上、検知漏れは誤送信 = 承認の肩代わりに直結するため fail-closed に倒す(判定不能なら送らない)。
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

**自動連鎖で投入してよいのは、承認済み分割計画に列挙されたタスクに限る**。これが連鎖の
天井で、総数は計画のサイズで自然に有界になる(別途の回数上限は置かない)。計画に無いタスクを
足したくなったら、それは**計画変更**なので連鎖を止めて人間承認へ戻す。

## 3. 案件 window と pane 構成

- **1 案件 = 1 tmux window**。中を**管理セッション pane + タスク pane 群**に分割する
  (相談役が隣で同時に見えること自体が価値のため pane 分割を採る)。
- **1 pane = 1 branch = 1 worktree**(既存規約)。複数タスク並列の案件は epic ブランチを
  派生させ、`~/ghq/github.com/Hirayama61/dotfiles/bin/wt.sh "<task-branch>" "<base-ref>"` で
  タスク別 worktree を base-ref 明示で作る(単一タスクの案件は feature 1 本でよい)。
  タスクブランチは**非保護 feature ブランチ**に限る(§4 のフラグが書かれる条件)。
- **pane 上限 = 既定 3**(管理 pane を除く。狭 pane 化の抑制)。**数えるのは稼働中のタスク pane
  のみ**で、forensics のため残している失敗 pane(§10)は上限に数えない。失敗 pane はログを
  吸い出したら畳んでよい。
- **上限の変更は非対称**: 引き下げは管理セッション判断で自由。**引き上げは人間承認事項**とする
  (同時に走る auto mode 被運転の本数を増やす操作のため)。
- **spillover window(pane 上限超過時)**: 上限超過分は**同一案件の副 window**
  (window 名 `<fleet-id>-w2` 等)へ逃がす。**案件単位は 1 window を基本とし、超過時のみ副
  window を派生する**(CONTEXT.md「1 案件 = 1 window」を保ちつつ、超過は例外的に副 window で
  受ける)。副 window は管理 pane を持たないので、管理セッションは §7 の Monitor で主 window の
  タスク pane と副 window の被運転を pane 別状態でまとめて監視する。

## 4. Gate 2 との噛み合わせ(フラグ展開)

案件設計は着手前に **design-review に一度通す**(この skill を回す前提)。管理セッションが
計画に**列挙された各タスクブランチ**へ design-reviewed の branch フラグを展開する
(**フラグ展開**。案件設計が design-review を一度通っている効力の継承であって素通しでは
ない。ツール改修は不要)。展開の作法は 3 つの順序制約を必ず守る:

1. **展開は worktree / ブランチを作った後に行う**(§3 の `wt.sh` の後)。分割計画に書いた
   ブランチ名と実際に作られたブランチ名が 1 文字でもずれると、フラグは不一致で Gate 2 に
   止まるか、逆にずれた先が別の実ブランチと一致して**計画外ブランチを誤解除**する。
   ブランチ名は計画の文字列ではなく、**作成済み worktree から実測して**使う。
2. **展開対象の一覧を人間へ提示して確認を取る**(分割計画の承認とは別に、フラグを書く対象
   そのものを目視させる)。1 件の誤展開が Gate 2 の誤解除になり、branch フラグは TTL を
   持たないため放置すると残り続ける。
3. **フラグには由来を書く**(空ファイルにしない)。読取側は存在だけを見るので互換だが、
   後から「なぜこのブランチが解錠されているか」を人間が追えるようにする。

**展開するのは `design-reviewed` だけで、`design-scope` は展開しない**。理由は 3 つ。
(a) `design-scope` を使う self-review の Tier 3 は surface-only の所見表示で push を止めないため、
scope が無いブランチで落ちるのは所見だけで、ゲートは無効化されない。(b) push は人間の hard
ゲートなので、宣言外の変更は最終的に人間の目を通る。(c) 2 つのフラグを別々に書くと
「`design-reviewed` は作れたが `design-scope` は失敗」という中途半端な状態が生まれ、しかも
再実行は `ln` の既存失敗で止まって復旧できない。さらに scope はタスクごとに中身が違うので、
ブランチと scope の対応付けを展開側で持つ必要が出る。この複雑さは (a)(b) で見た効果に見合わない。
scope が要るタスクは、そのタスクの被運転側 / 人間が当該ブランチで通常どおり
`/design-review` を通した時に書かれる。

- **fan-out したブランチの Tier 3 所見は信用しない**。`scope-deviation-check.sh` は branch 版の
  `design-scope` が無い時、repo 単位の `design-scope-pending`(鮮度 24h)へ**出力の scope ファイル名を
  見ないと気づけない形でフォールバックする**(`TIER3:` 行の `scope=` に pending 版の名前が出る)。
  fan-out した N 本のタスクブランチは同一 repo なので全て同じ pending を読み、それは案件全体の
  宣言スコープ = 個別タスクより必ず広い。結果は「所見が出ない」ではなく「広すぎる scope で照合されて
  誤った `OK` が出る」なので、SKIP より質が悪い。この状態のブランチで Tier 3 が `OK` でも、
  スコープ照合を通過した根拠にはならない。
- **案件設計の design-review は非保護ブランチ上で実行する**。保護ブランチ(`main` / `epic/*`)上で
  回すと design-review は branch 版でなく repo 単位の `design-scope-pending` へ書き、上の誤った `OK`
  を 24h 生む。epic を作った直後に epic 派生の非保護ブランチ 1 本を用意し、そこで通す。

```sh
# lib は判定の単一情報源。保護ブランチ一覧をここに複製しない。
# 構文破損 lib の直 source は bash が status 2 で即死し || 節も実行されないので、
# subshell で先に検査してから本 source する(code-resurrect-check.sh と同じ 3 段)。
LIB="$HOME/.claude/hooks/lib/resolve-base-ref.sh"
[ -r "$LIB" ] || { echo "lib 不達: resolve-base-ref.sh。中断" >&2; exit 1; }
( . "$LIB" ) >/dev/null 2>&1 || { echo "lib 破損: resolve-base-ref.sh。中断" >&2; exit 1; }
. "$LIB" || { echo "lib 読込失敗: resolve-base-ref.sh。中断" >&2; exit 1; }
type is_protected_branch >/dev/null 2>&1 \
  || { echo "lib 旧版: is_protected_branch 未定義。中断" >&2; exit 1; }
"$HOME/.claude/hooks/lib/flag-paths.sh" dir-ensure \
  || { echo "flag state dir の検証に失敗。中断" >&2; exit 1; }

# 展開対象は「作成済みタスク worktree のパス」で持つ(計画の文字列ではなく実体を起点にする)。
# 中身は §3 で wt.sh が作った worktree に限る。人間確認済みの一覧をそのまま使う。
task_worktrees=(/path/to/wt-a /path/to/wt-b)   # ← 呼び出し側が実パスで埋める
[ "${#task_worktrees[@]}" -gt 0 ] \
  || { echo "展開対象が空。フラグ展開の対象なし。中断" >&2; exit 1; }
fleet_id=""                                    # ← 呼び出し側が §7 の fleet-id で埋める
[ -n "$fleet_id" ] || { echo "fleet_id が未設定。由来を書けないので中断" >&2; exit 1; }

for wt in "${task_worktrees[@]}"; do
  branch="$(git -C "$wt" branch --show-current 2>/dev/null || true)"
  [ -n "$branch" ] || { echo "ブランチ名が引けない: ${wt}。中断" >&2; exit 1; }
  git -C "$wt" check-ref-format "refs/heads/$branch" \
    || { echo "不正なブランチ名: ${branch}。中断" >&2; exit 1; }
  # 保護ブランチは branch フラグを持てない。§3 の「タスクブランチは非保護に限る」に反する
  # 計画の誤りなので、黙って飛ばさず中断する(飛ばすと当該タスクだけ後から Gate 2 で止まる)。
  is_protected_branch "$branch" \
    && { echo "タスクブランチが保護ブランチ: ${branch}。計画を直すまで進めない。中断" >&2; exit 1; }
  # repo キーは各 worktree のパスから導出する(cwd 依存にしない)。
  repo="$("$HOME/.claude/hooks/lib/resolve-repo-key.sh" "$wt" 2>/dev/null || true)"
  [ -n "$repo" ] || { echo "repo key が引けない: ${wt}。中断" >&2; exit 1; }

  f="$("$HOME/.claude/hooks/lib/flag-paths.sh" design-reviewed "$repo" "$branch")"
  [ -n "$f" ] || { echo "フラグパスが引けない: ${branch}。中断" >&2; exit 1; }
  [ -L "$f" ] && { echo "フラグパスが symlink: ${f}。中断" >&2; exit 1; }
  # 既存フラグは「誰かが先に解錠キーを作った」異常。作成失敗とは別メッセージにする
  # (push 認可キーの検知性のため)。
  [ -e "$f" ] && { echo "既存フラグを検出(異常): ${branch}。由来を確認するまで進めない。中断" >&2; exit 1; }

  # temp に書き切ってから ln で配置する(create-review-flag.sh と同じ形)。$f を消す経路を
  # 持たないのが要点 — 空フラグは design-review の touch が作る正規状態なので、中身の有無で
  # 「自分の残骸」と「競合で他者が作った本物」を区別できない。ln は既存があれば失敗するので
  # 競合にも安全で、失敗しても $f は無傷。掃除するのは自分の temp だけ。
  tmp="$f.tmp.$$"
  trap 'rm -f "$tmp"' INT TERM
  # temp 書込も noclobber で開く($tmp は PID 込みで予測可能。stale な symlink 残骸が
  # あると素の > はリンク先へ書いてしまう)。
  # 本文は事実だけを書く(design-review の実在は機械確認していないので由来として主張しない。
  # 下の復旧手順がこの本文を判断材料に使う)。
  ( set -C; printf 'fan-out by task-fleet %s at %s\n' "$fleet_id" "$(date '+%Y-%m-%d %H:%M')" > "$tmp" ) \
    || { rm -f "$tmp"; echo "フラグ本文の書込に失敗: ${branch}。中断" >&2; exit 1; }
  ln "$tmp" "$f" \
    || { rm -f "$tmp"; echo "フラグ配置に失敗(既存 or 権限): ${branch}。中断" >&2; exit 1; }
  rm -f "$tmp"
  trap - INT TERM
done
```

- **CLI はパスを print するだけ**(`flag-paths.sh design-reviewed <repo> <branch>`)。branch の
  ハッシュサフィックス化は CLI 内 `flag_safe_branch` が担うので raw branch 名を渡す。
- **計画外ブランチへは展開しない**。展開対象は分割計画に列挙し、かつ人間が確認した worktree に
  限る。失敗は 1 件でも**中断**する(部分失敗を黙って進めると、そのタスク pane だけが後から
  Gate 2 に止まり原因が追えない)。
- **中断からの復旧はフラグを消さずに行う**。既存フラグ検出で止まったら、そのフラグの中身(由来)を
  読んで正規の `/design-review` 由来か過去の fan-out 由来かを判別し、**当該ブランチを展開対象の
  一覧から外して再実行する**(既に解錠されているので展開は不要)。**ゲートフラグの削除は人間承認
  事項**で、管理セッションが state dir で `rm` しない(誤って別ブランチの解錠状態を壊す・意図しない
  解錠を作るため)。作成失敗(権限 / dir)で止まった場合は原因を直してから再実行する。

## 5. 各タスクの運転

各タスク = 1 pane(または spillover 副 window の 1 pane)= 1 被運転セッション。運転手順は
tmux-claude-drive を参照し、次を渡す:

1. **pane を作る(起動先ターゲット = pane split)**: 管理 pane のある案件 window を split し、
   生成 pane id を決定論的に受け取る:
   `pane_id="$(tmux split-window -d -P -F '#{pane_id}' -t <session>:<window> -c "$task_worktree")"`
   (`-d` でフォーカスを管理 pane から奪わない、`-P -F '#{pane_id}'` で新 pane の id を直接取る。
   後付けの display-message で「どれが新 pane か」を当てない = 誤 pane 送信の穴を塞ぐ)。以後の
   send-keys / capture-pane / Monitor / 後片付けは、この `pane_id`(`%NN`)を対象に固定する。
   **生成直後に `pane_id` の形を検査して、空なら投入を中止する**:
   `case "$pane_id" in %[0-9]*) ;; *) echo "pane 生成に失敗。投入を中止" >&2; exit 1 ;; esac`
   (split は window に余地が無い時=pane が最小高を割る時に失敗して空を返す。空ターゲットへの
   send-keys がどこへ行くかは tmux の版に依るので、進めずに止める)。
2. **被運転を起動**: `claude --model opus`(permission-mode 指定なし = defaultMode=auto)。
   起動確認時に pane の auto mode 表示も確認する(tmux-claude-drive 手順 1)。**capture-pane が
   空を返しても 1 回で異常と判断せず、数秒待って再取得する**(pane を N 本同時に立ち上げる
   task-fleet では起動直後の空振りの確率が上がる)。新規 worktree の初回起動では **trust
   ダイアログ**が出る。これは起動指示に含まれる操作なので通してよく、§1 の権限プロンプト代理
   承認禁止の対象外(操作中に出る権限プロンプトとは別物)。
3. **補間値のサニタイズ(必須)**: 被運転へ literal 送信する値(fleet-id・taskkey・nonce・
   タスク指示書のパス)は、送る前に**単一行・制御文字なし**を保証し、fleet-id / taskkey / nonce は
   `[A-Za-z0-9._-]` へ正規化する(dev-pipeline §4-3 継承。改行混入は send-keys `-l` の途中確定=
   premature submit + クロスセッション注入経路になる)。ファイル名用の ID と人間向け表示名は別に
   持つ。**タスク間インターフェース契約は send-keys で送らない** — 契約文はタスク指示書に書き、
   送るのはそのパスだけにする(契約文は自由記述の散文で、repo 内のファイルや issue 由来の文面を
   含みうる。それを別セッションのプロンプトへ流し込むと、文中の命令文がそのまま指示として効く)。
4. **指示を注入**: literal 指示に、**そのタスクのタスク指示書のパスだけ**を渡し(handoff doc 全文は
   渡さない。§7)、「これだけ読んで担当タスクを実行せよ」「完了時に nonce を完了ファイル
   `~/obsidian/brain/Tasks/<repo>/.done-<fleet>-<taskkey>`(**絶対パスで注入する**)に書いて停止」を
   含める。被運転は task worktree を cwd に起動するため、相対パスで渡すと worktree 配下に書かれて
   管理セッションの完了検知が永久待ちになる。
   **「完了レポートの冒頭行にも同じ nonce を書く」ことを指示に含める**(§7 の完了条件が
   レポート側の nonce を要求するため。ここを指示しないと、指示に忠実な被運転ほどレポートに
   nonce を書かず完了検知に落ちる)。承認範囲の区別(**許可済みなのはこのタスク自体で、
   被運転側の hard ゲート=push/設計レビュー等・権限プロンプトは事前承認にならない**)、対話不能
   分岐での推奨案自己選択 + 理由記録も含める(tmux-claude-drive 手順 2)。
   **投入前に、その taskkey の完了ファイルが残っていれば削除する**(経路 B の再投入で前回の
   完了ファイルが残っていると、nonce は毎回採番し直すため「ファイルは在るが nonce が一致しない」
   状態を管理セッションが延々観測する)。
5. **Monitor で監視**(§7 の pane 別状態で束ねる)。完了検知は pane 本文でなく完了ファイルの出現 +
   nonce 一致で行う(入力=pane / 出力=ファイルの分離)。

## 6. 検品(レポート駆動 + 最終検品)

- **タスク単位はレポート駆動検品**: 管理セッションは成果物全文を読まず、被運転が書く**完了
  レポート**(やったこと・判断・懸念・成果物パス)と、後続レビュー / QA タスクの結果だけを読む。
  これがコンテキスト最適化の中心機構。
- **最終検品は統合後の epic 上で行う**: 案件の全タスクが done になり、§8 の merge が済んだ後に、
  管理セッションが epic ブランチ上でタスク全体を通したチェック(タスク間の契約整合・全体の
  一貫性)を行う。タスク単位のレポート駆動検品とは別物で、統合後にしか観測できないものを見る。

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
  - `kind` ∈ {impl, review, qa, report}(期待成果物と完了条件を決める)。**`kind` は分割計画で確定し
    handoff doc からのみ読む**。被運転が書く完了レポートの記述で `kind` を読み替えない(「これは
    調査タスクなので diff は出ない」と書けば `impl` の diff 要求を外せてしまう。読み替えが要るなら
    計画変更として人間へ戻す)。
  - `artifact_paths`(そのタスクの期待成果物の**絶対パス**一覧。完了検知はここを見る。レポート
    本文から成果物パスを拾わない)/ `dispatch_marker`(投入マーカーファイルの絶対パス。成果物の
    鮮度を `test -nt` で比べる基準。経路 B の再投入では置き直す)。
  - `branch` / `worktree` / `pane_id`(`%NN`)/ `window`(主 or `<fleet-id>-w2`)/ `nonce`。
  - `depends_on`(依存タスク key)/ `blocks`(後続タスク key)/ `interface`(契約の要点 or 参照)。
  - `report_path`(完了レポート)/ `forensics_log`(失敗時のログパス)/
    `rlr_signal_file`(§9 経路 A のタイマーがこの pane 用に使う `RLR_SIGNAL_FILE` の絶対パス)。
  - 許可遷移: `pending → running → review → done`、任意時点から `failed`。検品 NG は
    `review → failed`、経路 B 復元は `failed → running`。rate-limit 中は status を変えない
    (running のまま。forensics に記録)。
- **handoff doc は被運転へ渡さない**: handoff は管理セッションの状態真実源であって、被運転への
  入力ではない。被運転が読むのは**自タスクのタスク指示書だけ**にする(handoff 全文を渡すと、
  被運転 A が兄弟タスク B の nonce を読めてしまい、先に完了ファイルを書けば B の完了を偽装
  できる。並列化で新たに開いた面で、直列の dev-pipeline には無い)。
- **nonce と完了検知**: fleet+task ごとに管理セッションが起動時に一意採番(再利用しない)。完了
  検知は pane 本文 grep でなく専用完了ファイル
  `~/obsidian/brain/Tasks/<repo>/.done-<fleet>-<taskkey>` の出現 + 中身の nonce 一致で行う
  (指示エコーの自己反射誤検知を避ける)。nonce 一致だけを完了の根拠にせず、**下の `kind` 別テーブルの
  期待成果物**を併せて確認する(§8 の機械的最低検品を完了検知側へ前倒しする)。完了条件の正典は
  **下のテーブルとその直下の「全 `kind` 共通の追加条件」**で、他の箇所に完了条件を分散させない。
- **期待成果物はタスク種別ごとに定める**。分割計画で各タスクに `kind` を与え(§7 の schema に
  持つ)、完了検知はその種別の期待成果物だけを見る。**`diff` を必須にするのは実装タスクだけ**で、
  レビュー / QA / レポートのタスクは成果物が外部ファイルのみで、タスクブランチに diff を
  持たないのが正常。判定はすべて機械的に行い、本文の意味解釈を完了条件に使わない。

  | `kind` | 期待成果物(これを完了条件に使う) |
  |---|---|
  | `impl` | 完了レポート + タスクブランチに変更があること(下記の判定手順) |
  | `review` | 完了レポート + 指摘一覧ファイルが実在し空でないこと |
  | `qa` | 完了レポート + 検証結果ファイルが実在し空でないこと |
  | `report` | 完了レポート + レポート本体ファイルが実在し空でないこと |

  **全 `kind` 共通の追加条件**(上のテーブルと合わせて完了条件の正典を成す):
  - **完了レポートが必須**。`report_path` が実在し空でないこと。
  - **完了レポートの冒頭に当該タスクの nonce があること**(§5-4 で被運転へ書くよう指示する)。
  - **`report_path` / `artifact_paths` が投入マーカーより新しいこと**。

  この 3 条件は下記フェンスが**まとめて**機械化する(条件表に足したのに実装が伴わない形を作らない)。
  成果物ファイルのパスは `artifact_paths`(schema)から引き、レポート本文から拾わない。

  **この 3 条件が防ぐのは「前回成果物の使い回し・タスク取り違え」という事故であって、偽装ではない**。
  nonce は被運転当人が持っているのでレポートに貼れるし、mtime は `touch` で前進させられる。
  行き詰まった被運転が中身の無いファイルを置いて完了を主張する経路は、機械チェックでは塞げない
  (特に `review` / `qa` は成果物の非空だけが条件)。**意図的な偽装は機械的に検出できず、§8 の
  人間検品が唯一の防壁**である。ここを「機械チェックを通ったから人間検品は軽くてよい」と読まない。
  事前配置の検知としてより確実なのは、**投入直前に管理セッションが `artifact_paths` / `report_path` の
  不在を確認する**こと(管理セッション側の観測なので被運転が触れない)。これを主、鮮度判定を補助に置く。

  鮮度判定は時刻値を持たず、**投入時に基準ファイル(投入マーカー)を置いて `test -nt` で比べる**。
  epoch 形式の取り決めも `stat` の platform 差(`stat -f %m` / `stat -c %Y`)も要らなくなる。
  マーカーのパスは schema の `dispatch_marker` に持ち、**経路 B の再投入では必ず置き直す**
  (置き直さないと前回投入時の成果物が鮮度判定を通り、この条件唯一の効き目が消える。§5-4 の
  完了ファイル削除と同じ粒度の後始末)。

  ```sh
  # 投入時(§5-4 の直前): install -m 600 /dev/null "$dispatch_marker"
  # このフェンスは上の共通追加条件 3 つすべて(レポート実在・非空 / 冒頭の nonce /
  # 投入マーカー以後の鮮度)を機械化する。判定不能はすべて中断側へ倒す(fail-closed)。
  report_path=""       # ← §7 schema の report_path(絶対パス)で埋める
  dispatch_marker=""   # ← §7 schema の dispatch_marker(絶対パス)で埋める
  nonce=""             # ← §7 schema の nonce で埋める
  artifact_paths=()    # ← §7 schema の artifact_paths を 1 要素 1 パス(絶対パス)で埋める

  [ -n "$report_path" ] || { echo "report_path が未設定。中断" >&2; exit 1; }
  [ -n "$dispatch_marker" ] || { echo "dispatch_marker が未設定。中断" >&2; exit 1; }
  [ -n "$nonce" ] || { echo "nonce が未設定。中断" >&2; exit 1; }
  # marker が古いファイルへの symlink だと、成果物側の -L を全部通したうえで -nt 比較だけが
  # 無条件に通る(鮮度条件が消える)。基準点なので成果物と同じく lstat で先に弾く。
  [ -L "$dispatch_marker" ] \
    && { echo "投入マーカーが symlink: ${dispatch_marker}。鮮度判定不能。中断" >&2; exit 1; }
  [ -f "$dispatch_marker" ] \
    || { echo "投入マーカー不在: ${dispatch_marker}。鮮度判定不能。中断" >&2; exit 1; }

  # 呼び出し側が set -u で実行する場合に備え、要素数で分岐してから展開する
  # (bash 3.2 は set -u 下の "${arr[@]}" が空配列でエラーになる)。
  checked=("$report_path")
  if [ "${#artifact_paths[@]}" -gt 0 ]; then
    checked+=("${artifact_paths[@]}")
  fi

  for f in "$dispatch_marker" "${checked[@]}"; do
    # 相対パスは管理セッションの cwd 基準で解決され、同名の新しいファイルが全条件を通って
    # done に化ける(§5-4 が投入側で警戒しているのと同じ落とし穴)。
    case "$f" in /*) ;; *) echo "絶対パスでない: ${f}。中断" >&2; exit 1 ;; esac
  done

  for f in "${checked[@]}"; do
    # -f / -s / -nt は symlink を辿るので、別ファイルへの symlink 1 本で 3 条件を全通過できる。
    # lstat する -L を先に置く(§4 のフラグパス検査と同じ形)。
    [ -L "$f" ] && { echo "成果物が symlink: ${f}。done にしない" >&2; exit 1; }
    [ -f "$f" ] || { echo "成果物が不在: ${f}。done にしない" >&2; exit 1; }
    [ -s "$f" ] || { echo "成果物が空: ${f}。done にしない" >&2; exit 1; }
    [ "$f" -nt "$dispatch_marker" ] \
      || { echo "成果物が投入より古い: ${f}。done にしない" >&2; exit 1; }
  done

  # -F で nonce の正規表現化を、-- で先頭 - のオプション化を防ぐ(nonce は [A-Za-z0-9._-] へ
  # 正規化される規約なので - 始まりが起こりうる)。
  head -n 5 -- "$report_path" | grep -qF -- "$nonce" \
    || { echo "レポート冒頭に nonce なし: ${report_path}。done にしない" >&2; exit 1; }
  ```

  `review` タスクの「所見 0 件なら 0 件と明示する」は完了条件ではなく**タスク指示書側の要求**として
  書く(完了検知は空でないことだけを見る)。

  `impl` の変更判定は commit 済み差分と作業ツリーの両方を見る。**`git diff --quiet` の終了コードは
  `1` = 差分あり、`>1` = エラー**なので、非 0 をまとめて「差分あり」に倒さない(base 解決失敗や
  不正 ref が完了扱いに化ける)。`<base>` は自分で決めず `resolve-base-ref.sh` の `resolve_base_ref`
  から引く(タスクブランチは epic 派生なので最近接保護祖先が要る。判定の単一情報源は lib)。

  ```sh
  # このフェンスは単体で実行される(§4 とは別 Bash)。lib は必ずここで source する。
  # 直 source は構文破損時に bash が status 2 で即死し || 節が実行されないので、
  # §4 と同じく subshell 検査を先に挟む。
  LIB="$HOME/.claude/hooks/lib/resolve-base-ref.sh"
  [ -r "$LIB" ] || { echo "lib 不達: resolve-base-ref.sh。中断" >&2; exit 1; }
  ( . "$LIB" ) >/dev/null 2>&1 || { echo "lib 破損: resolve-base-ref.sh。中断" >&2; exit 1; }
  . "$LIB" || { echo "lib 読込失敗: resolve-base-ref.sh。中断" >&2; exit 1; }
  type resolve_base_ref >/dev/null 2>&1 \
    || { echo "lib 旧版: resolve_base_ref 未定義。中断" >&2; exit 1; }

  wt=""   # ← §7 schema の worktree(絶対パス)で埋める
  [ -n "$wt" ] || { echo "worktree が未設定。中断" >&2; exit 1; }

  base="$(resolve_base_ref "$wt")"
  [ -n "$base" ] || { echo "base 解決に失敗: ${wt}。完了判定は保留し人間へ" >&2; exit 1; }
  # ブランチ名がオプションに化けるのを防ぐ(run-codex-review.sh と同じガード)。
  case "$base" in -*) echo "base がオプション形: ${base}。中断" >&2; exit 1 ;; esac

  # 三点記法。二点(= tip 同士の比較)にすると、epic に兄弟タスクが merge されて base が
  # 前進しただけで、1 コミットもしていないタスクブランチが「差分あり」になり自動 done に化ける。
  committed=no
  rc=0; git -C "$wt" diff --quiet "$base"...HEAD -- || rc=$?
  case "$rc" in
    0) ;;
    1) committed=yes ;;
    *) echo "diff 判定に失敗(rc=$rc): ${wt}。完了判定は保留し人間へ" >&2; exit 1 ;;
  esac

  # 未 commit の作業ツリー変更も「変更あり」として拾う。HEAD を渡さないと staged 済み
  # 未 commit を取りこぼす。エラー(rc>1)は「変更なし」に倒さず判定不能として止める。
  dirty=no
  drc=0; git -C "$wt" diff --quiet HEAD -- || drc=$?
  case "$drc" in
    0) ;;
    1) dirty=yes ;;
    *) echo "dirty 判定に失敗(rc=$drc): ${wt}。完了判定は保留し人間へ" >&2; exit 1 ;;
  esac
  untracked="$(git -C "$wt" ls-files --others --exclude-standard)" \
    || { echo "untracked 判定に失敗: ${wt}。完了判定は保留し人間へ" >&2; exit 1; }
  [ -n "$untracked" ] && dirty=yes
  # 直前が && で終わるため、untracked が空(最も普通のケース)だとフェンス全体が
  # 非 0 終了になる。呼び出し側に失敗と誤読させないための no-op。消さないこと。
  :
  ```

  `committed=yes` なら完了条件を満たす。`committed=no` かつ `dirty=yes` は**未 commit**であって
  変更不要ではないので、done にせず被運転へ commit を促すか管理セッションが裁定する。両方 no の
  「本当に変更不要で終わった `impl`」も自動では done にせず、理由をレポートで確認したうえで
  管理セッションが done か failed かを裁定する(原因も対処も違うので同じ扱いにしない)。
- **並列 Monitor の pane 別状態**: tmux-claude-drive 手順 3 の Monitor は単一 pane 前提なので、
  task-fleet は**どの pane が 完了 / usage limit / 権限プロンプト / API Error / pane 消失か**を
  pane 別に持つ状態で、主 window のタスク pane 群 + spillover 副 window をまとめて監視する。
  同一 pane の同一イベントの重複発報はフラグで抑止する。

## 8. 統合(タスクブランチ → epic)

- タスクブランチ → epic ブランチの merge は**管理セッションが検品後に実施**する。
- **merge 前の機械的最低検品**(レポート駆動検品を崩さず、merge の事故面だけ下げる): 完了 nonce の
  一致・`git status`(dirty / 未 commit の確認)・タスクブランチの diff 要約・テスト結果・§7 の
  `artifact_paths` が指す成果物 path の存在確認(完了条件の正典は §7 のテーブル)。これらは全文
  通読ではない機械的チェックとして必ず通す。
  診断の粒度は §7 の `kind` に従う(merge 対象になるのは diff を持つ `impl` タスクで、
  `review` / `qa` / `report` タスクは merge せず成果物ファイルの確認だけで閉じる)。
- **軽微なコンフリクトは管理セッションが直接解決**してよい。ただし解決のための epic worktree 上の
  編集は**保護 epic ブランチ上で Gate 2(mutation)に当たる**(epic は保護ブランチで branch フラグを
  持てない)。解錠は (a) 人間承認の理由付き trivial-override、または (b) 後述の被運転投入経路
  (非保護 worktree で解決)へ寄せる。長尺案件では管理セッションの `design-reviewed-pending` が
  TTL 失効しうるため、締めの手編集を当てにせず被運転経路を既定に置くのが安全。
- **重いコンフリクトは統合タスクとして被運転へ**投入する(1 統合タスク = epic を base にした非保護
  worktree で解決させ、レポート駆動検品する)。
- **§6 の最終検品はこの merge の後**に、統合済みの epic 上で行う(タスク間の契約整合は統合後に
  しか観測できない)。merge 前に通すのは上記の機械的最低検品だけ。

## 9. 中断・再開(2 経路)

- **経路 A(レートリミット)**: 被運転プロセスは生存する前提。pane ごとに
  `<skills>/dev-pipeline/scripts/rate-limit-resume.sh <pane_id>` を起動する(素のシェルで
  Claude のレートリミットを消費しない)。banner が明けたら再開フレーズを 1 度送り、管理セッションは
  Monitor でその出力(`RLR: sent` / `resumed` / `route-b …`)を回収する。`route-b` が出たら経路 B へ。
  - **pane ごとに `RLR_SIGNAL_FILE` を分ける**(パスは §7 の `rlr_signal_file` に記録する)。複数
    タイマーを同時に走らせると、stdout だけではどの pane の `RLR: sent` / `route-b` かを安定して
    紐付けられない。signal file を pane 別に持てば、状態の帰属が pane_id で決まる。
  - **共有レートリミットの thundering-herd 対策**: 並列タスク pane は**同一アカウントの 1 つの
    レートリミットを共有**する(dev-pipeline は直列でこの問題に当たらない)。usage limit は全 pane に
    ほぼ同時到達し、明けた瞬間に N 本の再開が一斉送信 → 直後に再度リミット、を起こしうる。対策は
    **同時稼働本数を絞る**こと(リミット中は稼働 pane を減らし、明けたら順に再投入する)。
    「再開の時間差化」は当てにしない — `rate-limit-resume.sh` の送信時刻は banner から算出した
    deadline で決まるので、タイマーの起動時刻をずらしても送信は banner 消失から 1 ポーリング間隔
    以内に固まる。
- **経路 B(セッション死亡: kill / API Error / 検品 NG)**: handoff doc(状態真実源)+ その
  タスクの worktree の変更済みファイルから管理セッションが進捗を復元し、新しい被運転へ「ここまで
  済み」を注入して当該タスク頭から再開する(worktree 隔離により実差分は残る)。

## 10. 後片付け / forensics

- **検品済み pane は `kill-pane` で閉じる**(`kill-window` は使わない — 案件 window には管理 pane と
  兄弟タスク pane が同居するため、window ごと kill すると自分の観測点と並列作業を巻き込んで自壊する)。
  spillover 副 window は、その中の被運転を全て畳んだら window ごと kill してよい。
- **失敗 pane は kill せず残す**(forensics)。ただし残すのは**スクロールバックだけ**で、被運転
  プロセスは終了させ、pane 名に失敗マークを付ける(auto mode のセッションを生かしたまま放置すると、
  後から別作業で誤って入力・再開される)。ログを吸い出したらその pane は畳んでよい(§3 のとおり
  pane 上限には数えない)。**順序は (1) capture → (2) 失敗マークのリネーム → (3) 被運転プロセス終了
  に固定する**(pane のコマンドとして直接 `claude` を起動した場合、その終了で pane ごと消えて
  スクロールバックもリネーム対象も失われる。§5-1 のシェル経由起動なら pane は残るが、順序を
  固定すればどちらでも安全側。tmux-claude-drive の retain と同一の契約)。(2) と (3) は連続して
  実行し、間に調査を挟まない(失敗マーク済みでプロセスが生きている窓を作らない)。
  `capture-pane -J -p -S -2000 -t <pane_id>` で
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
