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
> mistakes.md 末尾 + 自動生成 MOC)を自動注入**する方式に置換した。関連する Tier1
> 本文は **Grep/Glob + [[wikilink]] でオンデマンド取得**する(MCP は使わず直接 FS
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

## 2. 書込フォーマット(必ず YAML frontmatter)

`templates/{knowledge,decision,project,preference}.md` を雛形に使う。

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

- `Knowledge/` = `topic-subtopic.md`(例 `nextjs-auth-cookie.md`)
- `Decisions/` = `YYYY-MM-DD-topic.md`(例 `2026-05-16-database-choice.md`)
- `Preferences/` = `category.md`(例 `coding-style.md`)
- `Projects/` = `project-name.md`

書く前に Grep/Glob で同主題ノートの有無を確認し、あれば追記(Edit)、無ければ
新規(Write)。

## 4. mistakes.md 追記(3条件 AND を満たす時のみ)

次の **3つを全て満たす時のみ** `Knowledge/mistakes.md` に追記する:

1. ユーザーからの明示的訂正である(自分の気づきでない)
2. 繰り返し起こり得るパターンである(偶発でない)
3. 具体的な「する / しない」で書ける

形式:

```
YYYY-MM-DD: [一言で何を間違えたか]
**NG Action**: 実際にやってしまった間違い
**Correct Action**: 次回からの正しい対応
**Trigger**: このルールが適用される状況
```

## 5. 報告(サイレント禁止)

読み書きしたら必ず明示する:

- `Obsidian: Knowledge/xxx.md を読みました`
- `Obsidian: Knowledge/xxx.md に書き込みました`

## 6. 作業スタイル

- シンプル・読みやすさ優先。不要な装飾・冗長説明を省く。
- 既存パターン・命名規則に合わせる。
- デプロイ・動作確認は自分で完結させる。

## 7. 形式の正しさ(skill 間連携)

wikilink / callout / properties など Obsidian ネイティブ記法の正確さは、
ext-skills マニフェスト(`mise run skills:sync`)で配置される kepano の
`obsidian-markdown` 等の skill に従う。
