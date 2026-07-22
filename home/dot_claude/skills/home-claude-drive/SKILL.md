---
name: home-claude-drive
description: >-
  tmux ホーム window に常駐する統括責任者のワークフロー。人間の依頼を受付けてタスク JSON 化し、
  window + 現場監督(被運転セッション)を配車し、fleet 状態ディレクトリで進捗とバックログを
  リポ横断管理する。運転(常時監視・検品)はせず、配車 + ナッジと人間への判断待ち提示に徹する。
  「ホームを立てて」「タスクを配車して」「今日の残タスクは」「fleet に積んで」、
  `/home-claude-drive` での起動で発火する。tmux-claude-drive(運転の手つき)・
  pane-claude-drive(現場監督の pane 並列)の 3 兄弟の統括層。
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Skill, Agent, AskUserQuestion
---

# home-claude-drive — ホームから配車する統括責任者

人間の唯一の定位置となる tmux **ホーム window** に常駐し、依頼の受付・タスク JSON 化・
window/現場監督の**配車**・**ナッジ**・リポ横断のバックログ管理を行う。実作業と window 内の
運転は現場監督(起動先の被運転セッション)に任せ、統括のコンテキストを軽く保つことが存在条件。
運転の手つき(起動・literal 送信・完了検知・後片付け)は **tmux-claude-drive skill を参照**し、
再実装しない。用語は `~/obsidian/brain/Tasks/cc-dotfiles/CONTEXT.md` の「claude-drive
シリーズ(area: home-claude-drive)」節が正典。

## 1. 前提と安全原則(最初に必ず)

- **統括の介入は配車 + ナッジまで**。送ってよいのは進行指示・再開フレーズ・状態書き忘れの
  督促・人間が口頭で下した判断の代筆。**人間判断(権限プロンプト / AskUserQuestion /
  hard ゲート = push・マージ・design-review)は要約 + 推奨案を人間へ提示する**。権限プロンプトへの
  応答キーは人間の口頭指示があっても代筆しない(permission laundering 防止。既存契約を継承)。
- **ナッジ送信前の権限プロンプト機械検知**(モデルの目視判断に依存しない)。pane へ何かを送る前に
  capture 末尾を照合し、一致したら送らずに人間へ上げる。ERE は転記せず公開口から取得する
  (fail-closed: 取得失敗・空なら送らない):

  ```bash
  ere="$("$HOME/.claude/skills/dev-pipeline/scripts/rate-limit-resume.sh" --print-permission-ere)" || ere=""
  [ -n "$ere" ] || { echo "PERMISSION_ERE を取得できない。ナッジを中止して人間へ" >&2; exit 1; }
  tail_txt="$(tmux capture-pane -t "$pane_id" -p | tail -15)"
  if printf '%s' "$tail_txt" | grep -qiE "$ere"; then
    echo "権限プロンプト滞留。送信せず人間へ要約提示" >&2
  fi
  ```

- **統括は運転をしない**: 全 pane への常時監視(Monitor / capture ポーリング)を張らない。
  状態把握は fleet 状態ディレクトリ(§2)が正で、capture-pane は異常時のドリルダウンに限る(§6)。
- **被運転の再帰運転禁止を継承**: 現場監督はさらに home-claude-drive を起動しない。現場監督が
  pane 並列するときは pane-claude-drive(旧 task-fleet)に従う。現場監督内部の通常の
  subagent 委譲は従来基準どおり行ってよい。
- **被運転モデルは `--model opus` 明示 + effort 自動ダイヤル**: 統括が作業内容で
  `--effort <low|medium|high|xhigh|max>` を指定してよい(難所 = 上げる / 機械的 = 下げる)。
  Sonnet 級で足りる定型は被運転を増やさず、現場監督内の subagent 委譲(worker/scout)で受ける。

## 2. fleet 状態ディレクトリ(スキーマ v1 正典)

**path 解決の canon(唯一の定義。読み手 = dotfiles の fleet-preview.sh はこれを逐語ミラー)**:

```bash
FLEET_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-fleet"
```

タスクは `$FLEET_DIR/tasks/<id>.json`(1 タスク = 1 ファイル)。完了は `$FLEET_DIR/done/` へ mv、
壊れ JSON は `$FLEET_DIR/corrupt/` へ mv(隔離は統括の専権。プレビューは読み取り専用)。
サブディレクトリは書込時に `mkdir -p` で遅延作成する。

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
- `status` ∈ `backlog | running | waiting-human | blocked | done`。
- `tmux_window`(`@NN`)/ `tmux_pane`(`%NN`)は不変 id。`window_name` = `id`(命名規約 §5)。
  未配車(backlog)はいずれも `""`。
- `next_action`: waiting-human のとき**人間がやること**を書く(プレビューの最重要列)。
- `context_pct`: 現場監督の自己申告(statusline からの機械書出は後続バックログ)。
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
- 右 pane にプレビューを起動する(トークンを消費しない素のシェルスクリプト。
  wt.sh と同じクロスリポ絶対パス参照):

  ```bash
  preview_pane="$(tmux split-window -d -P -F '#{pane_id}' -h -t "$home_pane" \
    ~/ghq/github.com/Hirayama61/dotfiles/bin/fleet-preview.sh)"
  case "$preview_pane" in %[0-9]*) ;; *) echo "プレビュー pane 生成に失敗" >&2 ;; esac
  ```

- pane 生成・送信は tmux-claude-drive 手順 1 の不変 pane id 契約(作成直前の取り直し +
  `%NN` 形検査 + 以後 id 宛固定)に従う。

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
4. **タスク JSON を更新**: status=running、`tmux_window` / `window_name` / `tmux_pane` /
   `branch` / `worktree` を実測値で記録(計画の文字列でなく作成済み実体から取る)。
   以後このファイルの更新は現場監督に移る(§2 writer 契約)。
5. **初期指示を literal 送信**(tmux-claude-drive 手順 2 の作法)。定型で必ず含める:
   - タスク内容と完了条件。整理要なら「まず /grill-with-docs」。
   - **状態ファイルの自己更新義務**: `$FLEET_DIR/tasks/<id>.json` を §2 スキーマで、
     状態変化時(着手・フェーズ移行・判断待ち・完了)と 30 分毎に原子的置換で更新すること。
     判断待ちは status=waiting-human + next_action に「人間がやること」を書くこと。
   - **コンテキスト規律**: 使用率 50% 超で native `/compact` を実行。逼迫が解消しない
     長期タスクは handoff を書いて新セッションへ退避し、新 pane id を状態ファイルに書き直す。
     (compact-prep 前段は未実装(設計中)のため参照しない。着地後にこの節へ挿入する。)
   - 完了時: status=done に更新して「最後に『<完了フレーズ>』とだけ書いて停止」。
   - hard ゲート(push / マージ / 権限プロンプト)は事前承認済みにならない旨。

## 6. 監視(状態ファイル正・capture はドリルダウンのみ)

- 状態把握は `$FLEET_DIR/tasks/*.json` の glob が正。人間との対話の切れ目で読み、
  waiting-human と停滞を拾う。
- **ドリルダウン条件**: `updated_at` が 30 分以上前のまま status=running、または status と
  実態の矛盾が疑われるときだけ、その pane を `tmux capture-pane -t "$pane_id" -p | tail -25` で
  覗く。原因に応じて: 書き忘れ → 督促ナッジ / 停止 → 再開ナッジ / 権限プロンプト(§1 の
  機械検知) → 人間へ要約提示 / pane 消失 → タスクを引き取り status=blocked + 人間へ報告。
- ナッジは 1 タスクにつき連続 2 回まで。効かなければ人間へ上げる(無限に突つかない)。

## 7. 人間への提示

「今日の残タスク」「次何やる」と聞かれたら、または対話の切れ目で判断待ちが溜まっていたら:

```text
## fleet 状況
判断待ち {N} 件:
| window | タスク | あなたがやること |
|---|---|---|
| dotfiles-tig-removal | tig 完全撤去 | 削除範囲の選択(window へ) |
稼働中 {M} 件 / バックログ {K} 件(リポ別内訳)
推奨: {次に見る window 1 つと理由}
```

window の案内は `window_name` で行う(pane が死んでいても window 名で辿れる)。

## 8. fail-open

- `$FLEET_DIR` 不在 → `mkdir -p` して空として扱う(エラーにしない)。
- 壊れた JSON(パース不能・スキーマ逸脱)→ `$FLEET_DIR/corrupt/` へ mv して人間へ 1 行報告。
  隔離は統括の専権で、プレビュー側は skip + 警告のみ(修復・削除をしない)。
- tmux が無い環境ではこの skill は成立しない。配車せず理由を明示して通常の対話に戻る。
