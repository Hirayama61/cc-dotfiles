---
name: obsidian-memory
description: >-
  Obsidian Vault(~/obsidian/brain)への永続記憶書込。バグ解決 / 新発見 / 判断 /
  状態変化 / 好み / 訂正が起きた瞬間に即時記録する。自動発火トリガ語:
  「覚えておいて」「方針として」「次回のために」「またミスった」「訂正」「初期セットアップして」。
allowed-tools: Read, Write, Edit, Grep, Glob
---

# obsidian-memory

`~/obsidian/brain` を外部脳とし、知見・判断・状態・好み・ミスを永続記憶へ書き込む。

> 翻案注記(原本からの差分): 原本「1.読み取り」は MCP でセッション開始時に毎回
> 読む前提だが、本 skill では **SessionStart hook が Preferences + 当該 repo の
> ルートガイド(`Guides/<repo>/<repo>-ガイド.md`)を自動注入**する方式に置換した。
> 関連する Tier1 本文(Mistakes/ 含む)は **Grep/Glob + [[wikilink]] でオンデマンド
> 取得**する(MCP は使わず直接 FS アクセス)。本 skill が担うのは **書込**(原本「2〜7」)。

## 役割分担(guide-capture との補完関係)

この skill が担うのは **Decisions / Preferences / Projects / Mistakes / Tasks** の
atomic ノートおよび作業ログの書込。
**運用知の現在状態(テスト規約・実装注意点・落とし穴など)** は別 skill `guide-capture`
が `Guides/<repo>/` の生きたガイドへ書く(current-state・人間ゲート付き)。
両者は直交する: Decisions は「なぜ=append-only 履歴」、ガイドは「今どうする=最新」。
一方を更新しても他方は不変であり、重複管理は起きない。

## 0. 前提: vault が無ければ

`~/obsidian/brain` が未存在なら `scripts/init-vault.sh` を案内する(冪等・既存
ノート不可侵)。`mise run obsidian:init` でも実行できる。

## 1. 書込先(どのフォルダに何を書くか)

該当したら **その場で書く。後回しにしない**。

- `Knowledge/` ← バグ / 問題が解決(原因と解決策をペアで)/ ライブラリ・API・
  ツールの新発見 / 環境構築・設定でハマって解決 /「次回同じ作業で知っておきたかった」こと。
  **共有・flat**(repo 別サブは作らない。横断の再利用資産)。
  **[注記] 運用知の新規蓄積は `guide-capture` 経由で `Guides/` へ。`Knowledge/` は
  archive 方針([[2026-06-09-外部脳を生きたガイド方式へ再設計]] 参照)。**
- `Decisions/` ← 複数選択肢から1つを選んだ判断(A vs B、なぜ A か)/ 設計・方針の決定
- `Projects/` ← プロジェクトの状態・バージョン・概要が変わった(1 repo 1ファイル・flat)
- `Preferences/` ← ユーザーの好み・作業スタイルを新たに発見(**共有・flat**)
- `Mistakes/` ← ミスの観測ログ(1ミス1ファイル)。防止の実装先ではなく、溜めた
  ログから人間/レビュー工程が CLAUDE.md / hook の防止ルールへ昇華する**材料**。
  1回目から軽量に記録してよい(詳細 §4)。
  **[注記] 運用知の新規蓄積は `guide-capture` 経由で `Guides/` へ。`Mistakes/` は
  archive 方針([[2026-06-09-外部脳を生きたガイド方式へ再設計]] 参照)。**

### repo スコープ(Decisions / Mistakes)

`Decisions/` と `Mistakes/` は repo 単位でサブディレクトリに分ける(taxonomy 案A):

- **repo 固有**の判断/ミス → `Decisions/<repo>/` `Mistakes/<repo>/`。
- **横断・メタ**(複数 repo に跨る判断、外部脳/hook/レビュー系などの運用基盤メタ、
  全 repo 共通の作業規律)→ `Decisions/_shared/` `Mistakes/_shared/`。**迷えば `_shared`**。
- `<repo>` は **現在の作業 repo の論理キー**。git toplevel の basename を使う(単一情報源 =
  `~/.claude/hooks/lib/resolve-repo-key.sh`。実体は cc-dotfiles の
  `home/dot_claude/hooks/lib/resolve-repo-key.sh`)。Bash で
  `~/.claude/hooks/lib/resolve-repo-key.sh "$PWD"` を実行すればキーが得られる。
- サブディレクトリは **書込時に `mkdir -p` で生やす**(init では先掘りしない)。
- `obsidian-memory` のような「1リポに紐付かない論理プロジェクト」のメタ判断は `_shared` 寄せ。

## 2. 書込フォーマット(必ず YAML frontmatter)

`templates/{knowledge,decision,project,preference,mistake}.md` を雛形に使う。

```
---
date: YYYY-MM-DD
tags: [relevant, tags]
project: project-name
related: [[Other Note]]
---
タイトル
本文。関連ノートには [[wiki link]] でリンクする。
```

作業成果物(plan / research / result 等の作業ログ)の既定書込先は
`~/obsidian/brain/Tasks/<repo>/`(repo スコープ。`<repo>` は §1 のリゾルバで導出。
リゾルバが空を返す非 git 文脈でだけ `Tasks/_misc/` に退避)。リポ作業ツリー配下の
新規 .md は PreToolUse(Write) hook がブロックするので、作業ドキュメントは Tasks へ
書く(詳細は delegate 規約)。

## 3. 命名規則

ファイル名は**日本語**にする。グラフビューのノードラベルはファイル名のベース名
そのもの(frontmatter の title/エイリアスはグラフに反映されない)なので、内容が
一目で分かるよう日本語化する。

- `Knowledge/` = `日本語トピック.md`(例 `macOSのbashに連想配列が無い.md`)
- `Decisions/` = `<repo>/YYYY-MM-DD-日本語トピック.md` or `_shared/YYYY-MM-DD-...md`
  (日付接頭辞は維持しソート性を残す。例 `dotfiles/2026-05-23-...md`・
  `_shared/2026-05-23-Obsidian外部脳アーキテクチャ.md`)
- `Preferences/` = `日本語カテゴリ.md`(例 `コーディングスタイル.md`)
- `Projects/` = `プロジェクト名.md`(プロジェクト名は実体に合わせ英語可)
- `Mistakes/` = `<repo>/YYYY-MM-DD-日本語トピック.md` or `_shared/...`(時系列ログなので
  日付接頭辞。並列 background で同日衝突しうるなら `YYYY-MM-DD-HHMMSS-...` で時刻も付す)

書く前に Grep/Glob で同主題ノートの有無を確認し、あれば追記(Edit)、無ければ
新規(Write)。

### wikilink は bare basename(戦略X)

ノート間リンクは **path 形式(`[[Decisions/...]]`)を使わず、ベース名のみの bare
形式(`[[2026-05-23-Obsidian外部脳アーキテクチャ]]`)で張る**。Obsidian 既定の
shortest 解決により、basename が vault 全体で一意ならどのフォルダに居ても解決する
→ Decisions/Mistakes を repo サブへ移動してもリンクが壊れない(将来の再編に強い)。

- **basename は vault 全体で一意に保つ**(これを恒久制約として受容)。日付接頭辞が
  実質ユニーク化に効く。衝突しそうなら日付/時刻でユニーク化する。
- frontmatter `related:` も bare 形式で書く(`related: ["[[bare 名]]"]`)。

> [!note] macOS は日本語ファイル名を NFD 正規化しがちで、NFC/NFD 不一致の落とし穴が
> ある(同じ見た目の名前が別物になる等)。詳細は Knowledge ノート
> `macOS日本語ファイル名のNFC-NFD正規化` を参照。

## 4. Mistakes/ への記録(観測ログ)

ミスは **防ぐ場所ではなく溜める場所**。ここはあくまで観測ログで、防止ルールの実装先は
CLAUDE.md と hook。溜めたログを人間/レビュー工程が見て、複数回発生したものを CLAUDE.md /
hook の防止ルールへ昇華する。**Tier0 への毎セッション自動注入はしない**(過去ミスは
Grep/Glob + [[wikilink]] でオンデマンド参照)。

記録基準は緩い:

- **1回目から記録してよい**。「複数回発生」かどうかは溜めたログを見て人間が判断するもので、
  記録段階で抑制しない。迷ったら書く。
- 旧「3条件 AND(明示的訂正 / 反復性 / する・しない断定)」は **撤廃**。する/しない断定は
  ルール昇華工程の仕事であって、記録時に求めない。

配置・命名:

- `Mistakes/<repo>/`(repo 固有)or `Mistakes/_shared/`(横断)に **1ミス1ファイル**
  (サブは書込時に mkdir。`<repo>` は §1 のリゾルバ導出)。
- ファイル名 `YYYY-MM-DD-日本語トピック.md`(§3 参照。NFC 統一・並列衝突時は時刻付与)。
- frontmatter は他ノート同様必須。`templates/mistake.md` を雛形に使う。

軽量フォーマット(素早く残せることを優先):

- **状況(Trigger)**: どういう作業・文脈で起きたか
- **何が起きたか**: 実際のミス(NG/Correct の断定は不要)
- **推測原因(任意)**: 分かれば。不明なら省略可

関連する既存ミスや昇華先(CLAUDE.md/hook の議論)があれば [[wikilink]] で繋ぐ。

## 5. 報告(サイレント禁止)

読み書きしたら必ず明示する:

- `Obsidian: Knowledge/xxx.md を読みました`
- `Obsidian: Knowledge/xxx.md に書き込みました`
- `Obsidian: Mistakes/<repo>/YYYY-MM-DD-xxx.md に記録しました`

## 6. 作業スタイル

- シンプル・読みやすさ優先。不要な装飾・冗長説明を省く。
- 既存パターン・命名規則に合わせる。
- デプロイ・動作確認は自分で完結させる。

## 7. 育てるドメインはグラフ前提の密リンクページにする

nvim / Oil 等の継続的に知見が増えるドメインは、**1ノートに延々追記しない**。
意味単位ごとにノートを分け、`[[wikilink]]` と tag で密に相互リンクする(グラフ
ビューが育ち、Claude の link 辿りの入口になる)。

- ドメインごとに **ハブノート** を1枚置く(例 `Knowledge/nvim.md`)。トピックノート群
  へ wikilink で繋ぐ起点にする。
- 分割の判断軸は「**リンクする価値があるか**」+ §1 の品質バー(再利用可能 / 非自明 /
  次回また調べ直すのを防ぐ)。
- **孤立(無リンク)ノートを作らない**。新規ノートは必ずハブ or 関連ノートへ
  wikilink で接続する。

## 8. 形式の正しさ(skill 間連携)

wikilink / callout / properties など Obsidian ネイティブ記法の正確さは、
ext-skills マニフェスト(`mise run skills:sync`)で配置される kepano の
`obsidian-markdown` 等の skill に従う。
