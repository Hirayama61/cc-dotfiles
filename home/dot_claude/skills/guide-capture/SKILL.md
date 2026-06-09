---
name: guide-capture
description: >-
  外部脳の「生きたガイド」(~/obsidian/brain/Guides)へ運用知の現在状態を書く。
  テスト規約 / 実装の注意点 / 落とし穴を、context(repo or 横断トピック)ごとの
  ルートガイドに current-state として蒸留・蓄積する。Decisions(なぜ=履歴)とは
  直交し、ここは「今こうする」の最新のみ。陳腐・矛盾は能動 prune、肥大は遅延分割。
  書込は必ず diff 提示 → 人間承認のゲート付き。作業中に運用知を学んだ際の
  proactive 提案、または `/guide-capture` 明示起動・「ガイドに書いて」で発火する。
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, AskUserQuestion
user-invocable: true
---

# guide-capture

`~/obsidian/brain/Guides` の **生きたガイド**(context ごとの運用知 current-state(現在状態))へ、
日々の作業で得た学びを蒸留して書き込む。狙いは「Claude Code を使うだけで運用知が
最新状態で蓄積・整理される」こと。

**このガイドは current-state のみ。** 「いつ何をした」の履歴ではなく「今こうする /
こう気をつける」の運用知を書く。「なぜ X を選んだか(履歴・トレードオフ)」は
Decisions の領分で、こことは**直交**する(混ぜない)。

**意味判断は Claude、最終ゲートは人間。** 蒸留・prune・分割の提案は Claude がするが、
**書込前に必ず diff を見せ、人間の承認を得てから書く**(陳腐削除・分割も承認時に行う)。
無検証の自動書込はしない(noise/誤情報が「最新のみ・正しい」を壊す)。

このスキルは 2 経路で呼ばれる:
- **随時 proactive 提案**(作業中に guide-worthy な運用知を学んだら、main がフル
  コンテキストで反映を提案する。CLAUDE.md の規律で発火)。
- **ユーザーの明示起動**(`/guide-capture`、「ガイドに書いて」等)。

---

## 1. 対象 context を解決する

書き込む先のガイドは **context 単位**(通常は repo、横断知はトピック)。

```sh
~/.claude/hooks/lib/resolve-repo-key.sh "$PWD"
```

- 返り値が **repo キー**(例 `dotfiles` / `cc-dotfiles`)なら → `Guides/<repo>/`。
  - worktree 隔離下でもこのリゾルバはメイン clone の repo 名を返す(branch leaf に
    ならない)。だから worktree で作業していても context は repo に集約される。
- **横断知**(特定 repo に紐づかない platform/tool/language の運用知。例 macOS の
  挙動、tmux/fzf、Go の落とし穴)→ `Guides/_topics/`。repo か横断かは学びの性質で
  判断する(「この repo でだけ効く」なら repo、「どの repo でも効く」なら `_topics`)。
- リゾルバが **空文字**を返す(非 git 文脈)時は、学びが横断知なら `_topics`、
  それも曖昧なら**人間に context を確認**してから進む(誤った場所に書かない)。

## 2. ルートガイドを lazy 確保する

context のルートガイドは決定的命名:

- repo: `~/obsidian/brain/Guides/<context>/<context>-ガイド.md`
- 横断: `~/obsidian/brain/Guides/_topics/<topic>.md`

手順:

1. Read を試みる。**在れば**全文を読み、現在状態を把握する。
2. **無ければ**最小構造で新規作成する(下記 §9 の雛形)。親ディレクトリは
   `mkdir -p ~/obsidian/brain/Guides/<context>` で生やす(init では先掘りしない)。
   中身は空でよい — キャプチャで埋まる。新規作成自体も §6 のゲート対象
   (「新しいガイドを作ります」と提示して承認を得る)。

> [!important] ルートは小さく保つ
> SessionStart hook は**ルートガイドだけ**を毎回注入する(サブ doc は注入しない)。
> だからルートは **概観 + [[link]]** に留め、詳細はサブ doc / `_topics` へ逃がす。
> ルートが肥大したら §5 の分割を発動する。

## 3. 学びを current-state に蒸留する

受け取った学び(テスト規約・実装の注意点・落とし穴など)を、**簡潔な現在状態**へ
蒸留して該当節に置く。

- **冗長な日本語文章を書かない**(Preferences のコーディングスタイルに準拠(`~/obsidian/brain/Preferences/`):
  一文一改行・要点は太字・飾り語/造語なし・専門語はかみ砕く)。
- **履歴形でなく運用知形**で書く。
  - NG(履歴): 「2026-06-09 にテストが落ちたので fixture を追加した」
  - OK(運用知): 「**テストは `mise run test` で実行**。fixture は `tests/fixtures/` に置く」
- 1 学び = 該当節への 1〜数行のエントリ。既存の節に収まるなら追記、無ければ節を足す
  (節構成の大きな変更は §6 で提示する)。
- 該当 context のガイドに既に**同主題のエントリがある**なら、新規追加でなく
  既存記述の**更新(置換)**として扱う(§4 の prune と一体)。

## 4. 陳腐・矛盾をチェックする(prune)

**古い情報を残さないことがこのガイドの中核要件。** 蒸留したエントリを置く前に、
対象 doc 内に新情報と**矛盾・重複する古い記述**が無いか走査する。

- 矛盾(古い手順 → 新しい手順に変わった)→ 古い記述の **置換**を提案。
- 重複(同じことが2箇所)→ 1箇所に**集約**し他を**削除**を提案。
- 新情報で**完全に陳腐化**した記述 → **削除**を提案。

prune は §6 の diff に「削除/置換」として必ず含め、**承認時に実行**する
(勝手に消さない)。陳腐記述を「念のため残す」はしない(current-only を壊す)。

## 5. 1コンテンツ違反をチェックする(遅延分割)

「1ドキュメント = 1コンテンツ」が破れたら分割する(**遅延分割 / 創発グラフ**)。
事前に分けず、**育って破れた時点で**初めて分ける。

分割の発火条件(いずれか):
- ルートガイドが**肥大**してきた(SessionStart 注入が重くなる)。
- ルートに**独立した複数コンテンツ**が同居している(例「テスト規約」が単独で
  1ページ分の厚みを持ち、概観から独立できる)。
- 学びが特定 repo を超える**横断知**だと判明した(→ `_topics/` へ)。

分割の手順(提案として §6 に載せる):
1. 該当する塊を **1コンテンツのサブ doc**(`Guides/<context>/<topic>.md`)または
   横断なら `Guides/_topics/<topic>.md` へ切り出す。
2. ルートには **[[link]] + 1行要約**だけ残す(本文はサブへ移す)。
3. サブ doc は**孤立させない** — ルート(or 関連ノート)から必ず [[link]] で繋ぐ
   (ハブ & スポーク。obsidian-memory §7)。横断 `_topics` は複数 repo ルートから
   [[link]] されうるハブノードになる。

## 6. diff 提示 → 人間承認 → 書込

**書込前に必ず変更を diff で見せ、承認を得てから書く。** これがこのスキルの安全弁。

- 変更の種類を明示して提示する: **追加 / 置換 / 削除 / 分割 / 新規ガイド作成**。
- 提示はまとめて出し、人間はスキム確認する(co-author 同様、提示と差分で承認を待つ)。
  重要な二者択一(どの context に書くか、分割するか否か等)は `AskUserQuestion` を使い、
  **必ず推奨案を添える**(「僕なら repo 側。理由は…」)。
- 承認後に Edit / Write で書く。**陳腐削除・分割も承認時にまとめて実行**する。
- 承認が得られない/曖昧なら書かない。スコープ外の気づきは申し送りに留める。

## 7. 報告(サイレント禁止)

obsidian-memory §5 と同じく、書いたら必ず明示する:

- `Obsidian: Guides/<context>/<context>-ガイド.md に書き込みました`
- `Obsidian: Guides/<context>/<topic>.md に分割しました(ルートに [[link]] を追加)`
- `Obsidian: Guides/_topics/<topic>.md に書き込みました`

新規作成・置換・削除も同様に何をしたか明示する。

## 8. 規約(obsidian-memory に従う)

ガイドも vault のノードなので obsidian-memory の規約を踏襲する:

- **ファイル名は日本語**(グラフのノードラベルになる)。**bare basename を vault
  全体で一意**に保つ([[wikilink]] は bare 形式 = ベース名のみ)。ルートは
  `<context>-ガイド` 接尾辞で `Projects/<repo>.md` 等と衝突回避。サブ/`_topics` は
  内容が一目で分かる topic 名で一意化(衝突しそうなら接頭辞を足す)。
- **macOS の NFC/NFD**: 日本語ファイル名は NFC に統一する(生成側と参照側=hook の
  [[link]] で同じ文字列を使う。`mv` 後は `python3 -c "import unicodedata"` で検証)。
  詳細は Knowledge `macOS日本語ファイル名のNFC-NFD正規化`。
- **孤立ノートを作らない**: サブ/`_topics` は必ずルート or 関連ノートから [[link]]
  で繋ぐ(§5)。
- **frontmatter 必須**(下記雛形)。`related:` は **bare wikilink**
  (`related: ["[[bare 名]]"]`)。
- 書く前に Grep/Glob で同主題の既存ガイド/サブ doc を確認し、あれば追記(Edit)・
  無ければ新規(Write)。

## 9. ルートガイドの最小雛形(lazy 作成時)

`<context>` を実際のキーに置換して書く。節は骨だけで中身は空でよい(キャプチャで
埋まる)。`related:` には関連 Decisions/Projects を bare wikilink で繋ぐ(無ければ空配列)。

```markdown
---
date: YYYY-MM-DD
tags: [guide, living-guide, <context>]
project: <context>
related: []
---
# <context> 生きたガイド

この repo で作業する際の**運用知の現在状態**。常に最新のみ・自己完結。
「なぜ(履歴・判断)」は Decisions、ここは「今こうする / こう気をつける」の最新だけ。

## テスト規約

## 実装の注意点・落とし穴

## アーキ前提
```

横断トピック(`_topics/<topic>.md`)は H1 を `# <topic>`、意図文を「複数 repo
で共通の運用知の現在状態」に変える(節構成はトピックに合わせて調整してよい —
節の変更は §6 で提示する)。
