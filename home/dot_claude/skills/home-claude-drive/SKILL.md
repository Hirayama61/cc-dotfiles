---
name: home-claude-drive
description: >-
  別 window を立てて現場監督(被運転セッション)を起動し、初期指示を渡すまでの配車の手つき。
  worktree 準備・window 作成・起動・literal 送信・fleet 台帳への記録・ナッジの上限を持つ。
  運転(常時監視・検品)も判断の取り次ぎもしない。相方(partner)が重い作業を別 window へ
  逃がす時に呼ぶ部品で、単体では「タスクを配車して」「fleet に積んで」、
  `/home-claude-drive` でも起動できる。運転の基礎は tmux-claude-drive、window 内の
  pane 並列は pane-claude-drive。
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Skill, Agent, AskUserQuestion
---

# home-claude-drive — 別 window へ配車する手つき

タスクを別 window へ送り出すまでの手順だけを持つ。worktree を用意し、window を作り、
現場監督を起動して初期指示を渡し、fleet 台帳へ配車先を記録するところで終わる。
運転の手つき(起動・literal 送信・完了検知・後片付け)は **tmux-claude-drive skill を参照**し、
再実装しない。

**この skill は役割ではなく手つきである**。ホーム window に立つ存在の定義は `partner`
(相方)が持ち、この skill はそこから呼ばれる部品。2026-07-26 に「統括責任者」の役割定義を
partner へ移し、配車の手つきへ純化した。用語は
`~/obsidian/brain/Tasks/cc-dotfiles/CONTEXT.md` の「相方(area: partner)」節および
「claude-drive シリーズ」節が正典。

## 1. 安全原則(最初に必ず)

- **介入は配車 + ナッジまで**。送ってよいのは進行指示・再開フレーズ・人間が口頭で下した
  判断の代筆。**人間判断(権限プロンプト / AskUserQuestion / hard ゲート = push・マージ・
  design-review)を要約して取り次がない** — 該当 window を名指しして人間をそこへ案内し、
  判断は現場監督と直接させる。権限プロンプトへの応答キーは人間の口頭指示があっても
  代筆しない(permission laundering 防止)。
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

- **配車は運転ではない**。全 pane への常時監視(Monitor / capture ポーリング)を張らない。
  capture-pane は異常が疑われる時のスポット確認に限る。
- **運転の入れ子は 2 段までで打ち止め**: 現場監督はさらに home-claude-drive を起動しない。
  現場監督が pane 並列するときは pane-claude-drive に従い、その作業者 pane はもう運転しない。
  現場監督内部の通常の subagent 委譲は従来基準どおり行ってよい。
- **被運転モデルは `--model opus` 明示 + effort 自動ダイヤル**: 配車側が作業内容で
  `--effort <low|medium|high|xhigh|max>` を指定してよい(難所 = 上げる / 機械的 = 下げる)。
  Sonnet 級で足りる定型は被運転を増やさず、現場監督内の subagent 委譲(worker/scout)で受ける。

## 2. fleet 状態ディレクトリ(スキーマ v2)

**用途はバックログ台帳と配車先の記録のみ**。走行中の進捗は持たない — 進捗欄は自己申告で
初日から腐ったため 2026-07-26 に廃止した(`phase` / `context_pct` / `next_action` /
`updated_at` を削除)。今どうなっているかは呼び出し側が `tmux list-windows` と
`capture-pane` で毎回測る。

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
  "status": "running"
}
```

フィールドの契約:

- `id` = `<repo>-<slug>`(ファイル名と一致。repo は `resolve-repo-key.sh` 準拠の論理キー)。
  **id は `^[A-Za-z0-9._-]+$` に限る** — パス・window 名へ内挿する値なので、書込と window
  作成の前に必ず検証する(タスク名の日本語は `title` に持たせ、slug は ASCII 化する):

  ```bash
  case "$id" in "" | *[!A-Za-z0-9._-]*) echo "不正な id。中止: $id" >&2; exit 1 ;; esac
  ```
- `status` ∈ `backlog | running | blocked | done`。判断待ちは持たない(pane を見て測る)。
- `tmux_window`(`@NN`)/ `tmux_pane`(`%NN`)は不変 id。`window_name` = `id`。
  未配車(backlog)はいずれも `""`。ただし現場監督の新セッション退避で pane は替わりうるので、
  **fleet の `tmux_pane` は配車側が最後に書いた時点の値**として読む。使う前に
  `tmux list-panes -t "$window_id"` で生存を確認し、消えていたら `tmux_window` から現行 pane を
  引き直して配車側が書き直す(現場監督には書かせない — 単一 writer を崩さない)。
- GitHub issue があれば `"issue": "<URL>"` を任意で持つ(リンクのみ。正にしない)。
- **writer は配車した側のみ**。現場監督は fleet を書かない(2026-07-26 変更。進捗欄が
  無くなり現場監督が書くべきものが消えたため、単一 writer を配車側へ寄せた)。
  完了裁定も配車側が行い、現場監督の done 書込を待たない(判定条件は §4)。
- **書込は原子的置換**(読み手の部分読みを防ぐ。bash 3.2 互換):

  ```bash
  mkdir -p "$FLEET_DIR/tasks"
  tmp="$FLEET_DIR/tasks/.${id}.tmp.$$"
  printf '%s\n' "$json_body" > "$tmp" && mv "$tmp" "$FLEET_DIR/tasks/${id}.json"
  ```

## 3. 配車

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
4. **初期指示を literal 送信**(tmux-claude-drive 手順 2 の作法)。送る文字列は
   **単一行・制御文字なしを保証してから送る**(pane-claude-drive §5-3 と同契約 — 改行の混入は
   `send-keys -l` の途中確定になり、premature submit とクロスセッション注入の経路になる)。
   長い指示はファイルへ書いてパスだけを送る。定型で必ず含める:
   - タスク内容と完了条件。要件が曖昧なら「まず /grill-with-docs で要件を確定してから着手」。
     grill の対話相手は人間なので、その window で人間待ちになる(配車側が隣で整理して
     要約を渡す伝言ゲームを作らない)。
   - **コンテキスト規律**: 使用率 50% 超で `compact-prep` → native `/compact`。逼迫が
     解消しない長期タスクは handoff を書いて新セッションへ退避する。
   - 完了時: 「最後に『<完了フレーズ>』とだけ書いて停止」。fleet への書込は求めない(§2)。
   - hard ゲート(push / マージ / 権限プロンプト)は事前承認済みにならない旨。
   - **反復レビューの打ち止め条件**(self-review 手順 5 と同じ規則。現場監督が自ブランチで
     self-review を回す局面はこの経路を通るので、ここに無いと際限なく周回する):
     「self-review で直すのは**判断が `必須`** の finding だけ(severity の `重大` とは別軸)。
     `推奨` 以下は直さず `triage:` へ記録する。軽微を直すための commit を作らない。
     4 周目でも `必須` が残るなら止めて報告する」。周回上限は目安で、fleet JSON にも
     現場監督のセッションにも周回数の出所は無い(§4 のナッジ上限と同じ best-effort)。
     打ち止めを支えるのは `必須` だけ直すという主条件の側で、そちらは周回に依存しない。
5. **送信成功を確認してからタスク JSON を running に更新**: `tmux_window` / `window_name` /
   `tmux_pane` / `branch` / `worktree` を実測値で記録(計画の文字列でなく作成済み実体から取る)。
   失敗の向きで扱いが逆になるので、混ぜない:
   - **送信に失敗したら running にせず**、status=backlog のまま window を畳んで人間へ報告する
     (初期指示を受け取っていない現場監督を running として孤児化させない)。
   - **送信は成功したが running への書込に失敗したら、window は畳まない**。現場監督は既に
     指示を受けて作業しているので、畳むのは作業の破棄になる。実測済みの `tmux_window` /
     `tmux_pane` を手元に保持したまま書込を再試行し、なお失敗するなら**その 2 つの id を添えて
     人間へ報告する**。台帳に載らない window を黙って残すと、次の配車で同名 window が並び、
     どちらが生きているか誰にも分からなくなる。

## 4. ナッジと完了裁定

配車後に送ってよいのは §1 の 3 項目(進行指示・再開フレーズ・人間が口頭で下した判断の代筆)
だけ。§1 の機械検知を必ず先に通す。

- ナッジは 1 タスクにつき連続 2 回まで。効かなければ人間へ上げる(無限に突つかない)。
  この回数は**呼び出し側のセッション内の best-effort カウント**で、fleet へは永続化しない。
  compact / 再起動でカウントは消えうるが、「効かなければ人間へ」の出口があるため有界。
- 権限プロンプト検知に一致したら、人間をその window へ案内する(要約して代理で答えない)。

**完了裁定も配車側が行う**(§2 の単一 writer 契約。現場監督の done 書込を待たない)。
**判定条件は tmux-claude-drive 手順 3 の「スピナー不在 AND 完了フレーズの単独行一致」**をそのまま
使い、ここで別基準を定義しない(§1 の「再実装しない」に従う)。fleet を読む時、`status=running` の
各タスクについて次の順で裁定する:

1. `tmux_window` が生きているか(`tmux list-windows -F '#{window_id}'` に一致があるか)。
2. 生きていれば pane 末尾を capture し、tmux-claude-drive 手順 3 の判定にかける。
   完了と判定できた時だけ `status=done` にして `$FLEET_DIR/done/` へ mv する。
3. **window / pane が消えていたら完了ではない** — `status=blocked` にして人間へ報告する。
   消滅はクラッシュ・rate limit 停止・人間の誤操作でも起きるので、done の根拠にしない
   (単一シグナルでの完了裁定は実測で偽陽性が 3 連発している)。

裁定を怠ると終わったタスクが `running` のまま残り、fleet を台帳として読む側の俯瞰が狂う。
逆に消滅を done と読むと、落ちた作業が完了として埋もれる。

## 5. fail-open

- `$FLEET_DIR` 不在 → `mkdir -p` して空として扱う(エラーにしない)。
- 壊れた JSON(パース不能・スキーマ逸脱)→ `$FLEET_DIR/corrupt/` へ mv して人間へ 1 行報告。
- tmux が無い環境ではこの skill は成立しない。配車せず理由を明示して通常の対話に戻る。
