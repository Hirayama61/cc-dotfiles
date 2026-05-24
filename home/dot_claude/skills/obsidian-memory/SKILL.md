---
name: obsidian-memory
description: >-
  Obsidian Vault(~/obsidian/brain)を外部脳とした永続記憶への書込。バグ解決 /
  新発見 / 判断 / プロジェクト状態変化 / 好みの発見 / ユーザーからの訂正が起きた
  瞬間に該当ノートへ即時記録する(「後で書く」はしない)。読込は SessionStart
  hook が Tier0 を自動注入するので不要。自動発火トリガ語: 「覚えておいて」
  「方針として」「次回のために」「またミスった」「訂正」「初期セットアップして」。
allowed-tools: Read, Write, Edit, Grep, Glob
---

# obsidian-memory

`~/obsidian/brain` を外部脳とし、知見・判断・状態・好み・ミスを永続記憶へ書き込む。

> 翻案注記(原本からの差分): 原本「1.読み取り」は MCP でセッション開始時に毎回
> 読む前提だが、本 skill では **SessionStart hook が Tier0(Preferences 全文 +
> 自動生成 MOC)を自動注入**する方式に置換した。関連する Tier1 本文(Mistakes/ 含む)
> は **Grep/Glob + [[wikilink]] でオンデマンド取得**する(MCP は使わず直接 FS
> アクセス)。本 skill が担うのは **書込**(原本「2〜7」)。

## 0. 前提: vault が無ければ

`~/obsidian/brain` が未存在なら `scripts/init-vault.sh` を案内する(冪等・既存
ノート不可侵)。`mise run obsidian:init` でも実行できる。

## 1. 書込先(どのフォルダに何を書くか)

該当したら **その場で書く。後回しにしない**。

- `Knowledge/` ← バグ / 問題が解決(原因と解決策をペアで)/ ライブラリ・API・
  ツールの新発見 / 環境構築・設定でハマって解決 /「次回同じ作業で知っておきたかった」こと
- `Decisions/` ← 複数選択肢から1つを選んだ判断(A vs B、なぜ A か)/ 設計・方針の決定
- `Projects/` ← プロジェクトの状態・バージョン・概要が変わった
- `Preferences/` ← ユーザーの好み・作業スタイルを新たに発見
- `Mistakes/` ← ミスの観測ログ(1ミス1ファイル)。防止の実装先ではなく、溜めた
  ログから人間/レビュー工程が CLAUDE.md / hook の防止ルールへ昇華する**材料**。
  1回目から軽量に記録してよい(詳細 §4)

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

## 3. 命名規則

ファイル名は**日本語**にする。グラフビューのノードラベルはファイル名のベース名
そのもの(frontmatter の title/エイリアスはグラフに反映されない)なので、内容が
一目で分かるよう日本語化する。

- `Knowledge/` = `日本語トピック.md`(例 `macOSのbashに連想配列が無い.md`)
- `Decisions/` = `YYYY-MM-DD-日本語トピック.md`(日付接頭辞は維持しソート性を残す。
  例 `2026-05-23-Obsidian外部脳アーキテクチャ.md`)
- `Preferences/` = `日本語カテゴリ.md`(例 `コーディングスタイル.md`)
- `Projects/` = `プロジェクト名.md`(プロジェクト名は実体に合わせ英語可)
- `Mistakes/` = `YYYY-MM-DD-日本語トピック.md`(時系列ログなので日付接頭辞。並列
  background で同日衝突しうるなら `YYYY-MM-DD-HHMMSS-...` で時刻も付す)

書く前に Grep/Glob で同主題ノートの有無を確認し、あれば追記(Edit)、無ければ
新規(Write)。

> [!note] macOS は日本語ファイル名を NFD 正規化しがちで、NFC/NFD 不一致の落とし穴が
> ある(同じ見た目の名前が別物になる等)。詳細は Knowledge ノート
> `macOS日本語ファイル名のNFC-NFD正規化` を参照。

## 4. Mistakes/ への記録(観測ログ)

ミスは **防ぐ場所ではなく溜める場所**。ここはあくまで観測ログで、防止ルールの実装先は
CLAUDE.md と hook。溜めたログを人間/レビュー工程が見て、複数回発生したものを CLAUDE.md /
hook の防止ルールへ昇華する。**Tier0 への毎セッション自動注入はしない**(過去ミスは MOC
索引からオンデマンドで辿る)。

記録基準は緩い:

- **1回目から記録してよい**。「複数回発生」かどうかは溜めたログを見て人間が判断するもので、
  記録段階で抑制しない。迷ったら書く。
- 旧「3条件 AND(明示的訂正 / 反復性 / する・しない断定)」は **撤廃**。する/しない断定は
  ルール昇華工程の仕事であって、記録時に求めない。

配置・命名:

- トップレベル `Mistakes/` に **1ミス1ファイル**。
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
- `Obsidian: Mistakes/YYYY-MM-DD-xxx.md に記録しました`

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
