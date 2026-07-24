---
name: home-claude-drive
description: >-
  tmux ホーム window に常駐する統括責任者のワークフロー。人間の依頼を受付けてタスク JSON 化し、
  window + 現場監督(被運転セッション)を配車し、バックログと「今どの window が人間待ちか」を
  リポ横断で掲示する。運転(常時監視・検品)も判断の集約もせず、受付 + 配車 + 掲示に徹する。
  「ホームを立てて」「タスクを配車して」「今日の残タスクは」「fleet に積んで」、
  `/home-claude-drive` での起動で発火する。tmux-claude-drive(運転の手つき)・
  pane-claude-drive(現場監督の pane 並列)の 3 兄弟の統括層。
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Skill, Agent, AskUserQuestion
---

# home-claude-drive — ホームから配車する統括責任者

人間の入口となる tmux **ホーム window** に常駐し、依頼の受付・タスク JSON 化・
window/現場監督の**配車**・**ナッジ**・リポ横断のバックログ管理を行う。実作業と window 内の
運転は現場監督(起動先の被運転セッション)に任せ、統括のコンテキストを軽く保つことが存在条件。
運転の手つき(起動・literal 送信・完了検知・後片付け)は **tmux-claude-drive skill を参照**し、
再実装しない。用語は `~/obsidian/brain/Tasks/cc-dotfiles/CONTEXT.md` の「claude-drive
シリーズ(area: home-claude-drive)」節が正典。

**統括は「受付 + 掲示板」であって判断の集約点ではない**。依頼を受けて window を立てるところ
までと、「どの window が人間待ちか」を掲示するところまでが担当で、タスクの中身の判断は人間が
その window へ行って現場監督と直接する。統括を経由した判断リレーを既定にしない — 判断の文脈は
window 側にあり、統括が取り次ぐと文脈が剥がれて往復が増える(2026-07-23 の実運用で 2 回発生)。

## 1. 前提と安全原則(最初に必ず)

- **統括の介入は配車 + ナッジまで**。送ってよいのは進行指示・再開フレーズ・状態書き忘れの
  督促・人間が口頭で下した判断の代筆。**人間判断(権限プロンプト / AskUserQuestion /
  hard ゲート = push・マージ・design-review)を統括が要約して取り次がない** — 該当 window を
  名指しして人間をそこへ案内し、判断は現場監督と直接させる。権限プロンプトへの
  応答キーは人間の口頭指示があっても代筆しない(permission laundering 防止。既存契約を継承)。
- **ナッジ送信前の権限プロンプト機械検知**(モデルの目視判断に依存しない)。pane へ何かを送る前に
  capture 末尾を照合し、一致したら送らずに人間へ上げる。ERE は転記せず公開口から取得する。
  **全段 fail-closed** — ERE 取得失敗・pane_id 不正・capture 失敗・ERE 一致のいずれでも
  送信経路を確実に断つ(下の fence をそのまま使い、echo だけで送信に進む形にしない):

  ```bash
  ere="$("$HOME/.claude/skills/tmux-claude-drive/scripts/rate-limit-resume.sh" --print-permission-ere)" || ere=""
  [ -n "$ere" ] || { echo "PERMISSION_ERE を取得できない。ナッジを中止して人間へ" >&2; exit 1; }
  case "$pane_id" in %[0-9]*) ;; *) echo "pane_id 不正。送信中止" >&2; exit 1 ;; esac
  tail_txt="$(tmux capture-pane -t "$pane_id" -p)" || { echo "capture 失敗。送信中止" >&2; exit 1; }
  tail_txt="$(printf '%s\n' "$tail_txt" | tail -25)"
  # grep は 0=一致 / 1=不一致 / 2 以上=エラー(不正 ERE 等)。エラーを不一致に倒すと
  # 検知不能のまま送信に進む。
  # -a: agent shell の grep は -I 相当が効き、不正 UTF-8 を含む pane をバイナリ扱いして
  #     一致を rc=1(=唯一の続行値)で返す。herestring: pipefail 下で grep -q の早期終了が
  #     printf に SIGPIPE を返し、一致が rc=141 に化けるのを避ける。
  mrc=0; grep -aqiE -e "$ere" <<<"$tail_txt" || mrc=$?
  case "$mrc" in
    0) echo "権限プロンプト滞留。送信せず人間へ要約提示" >&2; exit 1 ;;
    1) ;;
    *) echo "ERE 照合に失敗(rc=$mrc)。送信中止" >&2; exit 1 ;;
  esac
  ```

  (検知窓は末尾 25 行 — rate-limit-resume.sh 本体・tmux-claude-drive 手順 3 と同幅に揃える。)

- **統括は運転をしない**: 全 pane への常時監視(Monitor / capture ポーリング)を張らない。
  capture-pane は人間に状況を聞かれた時と異常が疑われる時のスポット確認に限る(§6)。
- **運転の入れ子は 2 段までで打ち止め**: 現場監督はさらに home-claude-drive を起動しない。
  現場監督が pane 並列するときは pane-claude-drive に従い、その作業者 pane はもう運転しない。
  現場監督内部の通常の subagent 委譲は従来基準どおり行ってよい。
- **被運転モデルは `--model opus` 明示 + effort 自動ダイヤル**: 統括が作業内容で
  `--effort <low|medium|high|xhigh|max>` を指定してよい(難所 = 上げる / 機械的 = 下げる)。
  Sonnet 級で足りる定型は被運転を増やさず、現場監督内の subagent 委譲(worker/scout)で受ける。

## 2. fleet 状態ディレクトリ(スキーマ v1 正典)

**用途はバックログ台帳と配車先の記録**。走行中タスクの進捗欄は現場監督の自己申告で、
書き忘れを機械で強制する仕組みは置かない方針のため、鮮度を当てにしない(§6)。

**path 解決の canon(唯一の定義)**:

```bash
FLEET_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-fleet"
```

タスクは `$FLEET_DIR/tasks/<id>.json`(1 タスク = 1 ファイル)。完了は `$FLEET_DIR/done/` へ mv、
壊れ JSON は `$FLEET_DIR/corrupt/` へ mv。サブディレクトリは書込時に `mkdir -p` で遅延作成する。

```json
{
  "id": "dotfiles-tig-removal",
  "title": "tig 完全撤去",
  "repo": "dotfiles",
  "branch": "feat/remove-tig",
  "worktree": "/Users/h61/worktrees/github.com/Hirayama61/dotfiles/feat/remove-tig",
  "tmux_window": "@15",
  "window_name": "dotfiles-tig-removal",
  "tmux_pane": "%12",
  "status": "running",
  "phase": "impl",
  "context_pct": 34,
  "next_action": "削除範囲の選択待ち",
  "updated_at": "2026-07-22T18:00:00+09:00"
}
```

フィールドの契約:

- `id` = `<repo>-<slug>`(ファイル名と一致。repo は `resolve-repo-key.sh` 準拠の論理キー)。
  **id は `^[A-Za-z0-9._-]+$` に限る** — パス・window 名へ内挿する値なので、書込と window
  作成の前に必ず検証する(タスク名の日本語は `title` に持たせ、slug は ASCII 化する):

  ```bash
  case "$id" in "" | *[!A-Za-z0-9._-]*) echo "不正な id。中止: $id" >&2; exit 1 ;; esac
  ```
- `status` ∈ `backlog | running | waiting-human | blocked | done`。
- `tmux_window`(`@NN`)/ `tmux_pane`(`%NN`)は不変 id。`window_name` = `id`(命名規約 §5)。
  未配車(backlog)はいずれも `""`。「不変」は tmux がその id を振り直さない(常に同一
  window/pane を指す)ことであって、**タスクの生涯で値が固定という意味ではない** —
  現場監督の新セッション退避(§5)などで pane が替わったら、現行 writer が新しい id に
  更新する(古い id を使い続けない)。
- `next_action`: waiting-human のとき**人間がやること**を書く(§7 の掲示で使う最重要欄)。
- `context_pct`: 現場監督の自己申告(任意。statusline からの機械書出は行わない)。
- GitHub issue があれば `"issue": "<URL>"` を任意で持つ(リンクのみ。正にしない)。
- **writer 契約(単一 writer)**: 配車後の running タスクのファイルを統括は直接編集しない。
  更新は現場監督のみ。統括が書くのは (a) backlog の作成・編集、(b) done へのアーカイブ mv、
  (c) 現場監督死亡を確認したタスクの引き取り(status 変更)、(d) corrupt 隔離、に限る。
- **書込は原子的置換**(読み手の部分読みを防ぐ。bash 3.2 互換):

  ```bash
  mkdir -p "$FLEET_DIR/tasks"
  tmp="$FLEET_DIR/tasks/.${id}.tmp.$$"
  printf '%s\n' "$json_body" > "$tmp" && mv "$tmp" "$FLEET_DIR/tasks/${id}.json"
  ```

## 3. ホーム window の構成

- 現 tmux セッションの window を 1 つ `home` と命名して常駐する(統括セッションの定位置)。
- **ホーム window は統括セッション 1 pane だけで構成する**。常駐する状態表示 pane は置かない
  — 状況は人間に聞かれた時に §6 のやり方で答える。
- pane 生成・送信(配車先 window の作成など)は tmux-claude-drive 手順 1 の不変 pane id 契約
  (作成直前の取り直し + `%NN` 形検査 + 以後 id 宛固定)に従う。

## 4. 受付

人間の依頼を次の 3 択に判定する。判定に迷ったら人間に 1 問だけ確認する:

1. **即配車可**(要件が明確・単一タスク) → タスク JSON を作成(status=backlog)→ §5 で配車。
2. **整理要**(要件が曖昧・分割が要る) → タスク JSON 作成 + 配車し、**初期指示に
   「まず /grill-with-docs で要件を確定してから着手」を含める**(現場監督の初仕事。
   grill の対話相手は人間なので、その window が waiting-human になる。統括の隣 pane で
   整理して要約を渡す伝言ゲームを作らない)。
3. **積むだけ**(今やらない) → status=backlog の JSON 作成のみ。配車しない。

「今日の残タスクは」「次何やる」への応答は §7。

## 5. 配車

1. **worktree 準備**(リポ作業を伴うタスク):
   `~/ghq/github.com/Hirayama61/dotfiles/bin/wt.sh "<branch>" "<base-ref>"` を base-ref 明示で
   呼ぶ(既存規約)。branch は非保護 feature ブランチに限る。
2. **window 作成**: window 名 = タスク `id`。tmux-claude-drive 手順 1 に従い、作成直前に
   状態を取り直し、不変 pane id を受け取る形で作成・形検査する:

   ```bash
   pane_id="$(tmux new-window -P -F '#{pane_id}' -t "$session": -n "$task_id" -c "$workdir" -d)"
   case "$pane_id" in %[0-9]*) ;; *) echo "window 生成に失敗。配車を中止" >&2; exit 1 ;; esac
   window_id="$(tmux display-message -p -t "$pane_id" '#{window_id}')"
   ```

3. **現場監督を起動**: `claude --model opus`(+ 必要なら `--effort`)。起動確認・auto mode
   表示確認は tmux-claude-drive 手順 1 のとおり。
4. **初期指示を literal 送信**(tmux-claude-drive 手順 2 の作法)。定型で必ず含める:
   - タスク内容と完了条件。整理要なら「まず /grill-with-docs」。
   - **状態ファイルの自己更新義務**: `$FLEET_DIR/tasks/<id>.json` を §2 スキーマで、
     状態変化時(着手・フェーズ移行・判断待ち・完了)と 30 分毎に原子的置換で更新すること。
     判断待ちは status=waiting-human + next_action に「人間がやること」を書くこと。
   - **コンテキスト規律**: 使用率 50% 超で native `/compact` を実行。逼迫が解消しない
     長期タスクは handoff を書いて新セッションへ退避し、新 pane id を状態ファイルに書き直す。
     (compact-prep 前段は未実装(設計中)のため参照しない。着地後にこの節へ挿入する。)
   - 完了時: status=done に更新して「最後に『<完了フレーズ>』とだけ書いて停止」。
   - hard ゲート(push / マージ / 権限プロンプト)は事前承認済みにならない旨。
5. **送信成功を確認してからタスク JSON を running に更新**: `tmux_window` / `window_name` /
   `tmux_pane` / `branch` / `worktree` を実測値で記録(計画の文字列でなく作成済み実体から取る)。
   以後このファイルの更新は現場監督に移る(§2 writer 契約)。**送信に失敗したら running に
   せず**、status=backlog のまま window を畳んで人間へ報告する(初期指示を受け取っていない
   現場監督を running として孤児化させない)。

## 6. 状況確認(聞かれたら pane を直接見る)

常時監視は張らない。状況を答える必要が出た時にだけ、次の順で調べる:

1. `$FLEET_DIR/tasks/*.json` の glob で**どのタスクがどの window/pane にいるか**を引く
   (所在の台帳としては信頼できる。配車時に統括自身が実測値を書くため)。
2. **進捗と判断待ちは、その pane を `tmux capture-pane -t "$pane_id" -p | tail -25` で
   直接見て答える**。JSON の `status` / `updated_at` は現場監督の自己申告で書き忘れが起きるため、
   これを進捗の正としない(2026-07-23 に配車した 4 window 全てで waiting-human の書き忘れが発生)。
   状態ファイル契約を機械で強制する hook は作らない方針なので、読む側が pane を見る。
3. 見た結果に応じて動く: 停止 → 再開ナッジ / 権限プロンプト(§1 の機械検知に一致)→ 人間を
   その window へ案内 / pane 消失 → タスクを引き取り status=blocked + 人間へ報告。

ナッジの上限は次のとおり:

- ナッジは 1 タスクにつき連続 2 回まで。効かなければ人間へ上げる(無限に突つかない)。
  この回数は**統括セッション内の best-effort カウント**で、fleet 状態ファイルへは永続化
  しない(running ファイルの writer は現場監督 — 単一 writer 契約 §2 を優先)。統括の
  compact / 再起動でカウントは消えうるが、「効かなければ人間へ」の出口があるため有界。

## 7. 掲示(人間への提示)

「今日の残タスク」「次何やる」と聞かれたら、§6 の順で調べてから掲示する。掲示するのは
**どこに何があり、どれが人間待ちか**までで、判断の中身は window 側へ送る:

```text
## fleet 状況
判断待ち {N} 件:
| window | タスク | あなたがやること |
|---|---|---|
| dotfiles-tig-removal | tig 完全撤去 | 削除範囲の選択(window へ) |
稼働中 {M} 件 / バックログ {K} 件(リポ別内訳)
推奨: {次に見る window 1 つと理由}
```

window の案内は `window_name` で行う(pane が死んでいても window 名で辿れる)。ただし
window 名 = タスク id なので**再配車で同名 window が並びうる**。同名が 2 つ以上ある時は
`tmux_window`(`@NN`)も併記して人間が取り違えないようにする。

## 8. fail-open

- `$FLEET_DIR` 不在 → `mkdir -p` して空として扱う(エラーにしない)。
- 壊れた JSON(パース不能・スキーマ逸脱)→ `$FLEET_DIR/corrupt/` へ mv して人間へ 1 行報告。
- tmux が無い環境ではこの skill は成立しない。配車せず理由を明示して通常の対話に戻る。
