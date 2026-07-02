---
name: fe-qa
description: >-
  実装完了後のフロントエンド QA。Playwright MCP で人間相当の動作確認を行う —
  変更画面の操作フロー通し・フォーム境界値/エラー系・console/network エラー検知・
  視覚照合(figma-visual-check)・レスポンシブ・仕様適合(WBS+Confluence 両建て)・
  既存操作と権限別アカウントへの影響。「QA して」「動作確認して」「実装の検証」、
  `/fe-qa` での起動、または fe-implement からのハンドオフで発火する。
user-invocable: true
allowed-tools: Bash, Read, Write, Grep, Glob, Skill, AskUserQuestion, WebFetch
---

# fe-qa — Playwright による人間相当の QA

実装が「書けた」と「使える」の間を埋める。検査は 7 レンズを順に回し、
できなかったレンズは**「skip(理由)」を必ず明示**する(サイレント省略が最大の敵。
skip だらけの QA は QA ではない — 3 レンズ以上 skip なら人間にその旨を先に伝える)。

## 0. per-repo QA 設定

`~/.config/claude-qa/<repo>.yaml`(git 管理外・マシンローカル)から読む。
`<repo>` は `~/.claude/hooks/lib/resolve-repo-key.sh "$PWD"` で導出。

- **不在なら初回セットアップ**: 同梱 `templates/qa-config.yaml.example` を雛形に、
  dev サーバ起動コマンド・base URL・権限ロール別テストアカウントを人間に確認しながら
  対話で生成する(認証情報を含むためリポに commit しない。既存パターン=機密語リストと同型)。
- accounts が 1 ロールしか無ければ、レンズ 7 の権限比較は「skip(単一ロール)」になる。

## 1. 入力確定

- 対象: 変更画面・機能の一覧(fe-implement のハンドオフ、または diff / 人間から)。
- 仕様: **案件 WBS JSON(`~/obsidian/brain/Tasks/<repo>/*-wbs.json`)+ Confluence(MCP)の
  両建て**で読む(WBS は完全ではない前提で相互補完)。片方しか無ければその旨を記録。
- dev サーバを設定のコマンドで起動し、base URL の疎通を確認する。起動不能なら
  QA 全体を中断して人間に報告する(壊れた環境で「QA 済み」を作らない)。

## 2. 検査 7 レンズ

Playwright MCP(`browser_navigate` / `browser_snapshot` / `browser_click` /
`browser_fill_form` / `browser_console_messages` / `browser_network_requests` /
`browser_resize` / `browser_take_screenshot`)で実施する。

| # | レンズ | やること |
|---|---|---|
| 1 | 操作フロー | 変更画面ごとに主要ユースケースを通しで操作(遷移・クリック・保存・戻る)。人間が初見で触る順に辿る |
| 2 | フォーム | 境界値・エラー系(空・最大長・不正形式・全角/半角)を入力し、バリデーション文言と送信可否を確認 |
| 3 | console/network | 各操作後に console エラー・warning と failed request を機械検知(0 件が期待値。既存由来のノイズは区別して記録) |
| 4 | 視覚照合 | `figma-visual-check` skill を全画面パスで起動(実装中の単位照合の取りこぼし検出) |
| 5 | レスポンシブ | 設定のビューポート群(既定: 375 / 768 / 1440)で崩れ・横スクロール・要素の重なりを確認 |
| 6 | 仕様適合 | WBS の機能項目 + Confluence の仕様文を 1 項目ずつチェックリスト化し、画面の実挙動と突合(満たす/満たさない/仕様が曖昧) |
| 7 | 影響チェック | 変更画面に隣接する既存操作(一覧→詳細→編集の既存動線)の退行確認 + 権限ロール別アカウントでログインし直し、表示/操作可否が仕様どおりか確認 |

- レンズ 6 で「仕様が曖昧」になった項目は不具合ではなく**課題**として分離する
  (wbs-plan の課題様式に倣い、確認先を付けて人間へ)。
- 検査中のスクリーンショットは要所(不具合の証跡)のみ保存し、報告にパスを添える。

## 3. 結果の統合とトリアージ

self-review と同じ様式で提示する:

1. 概要ヘッダー(件数のみ): `重大 N / 改善 N / 情報 N + レンズごとの 実施/skip(理由)`。
2. finding を 1 件ずつ AskUserQuestion でトリアージ(`今すぐ修正` / `見送る` /
   `詳細を見る`)。severity は 重大=機能不全・データ破壊・権限漏れ / 改善=仕様不一致・
   視覚差分 / 情報=ノイズ・既存由来。
3. 記録テーブル(ID / レンズ / 場所 / 概要 / 対応)+ 総評。`今すぐ修正` があれば
   fe-implement(または通常の修正フロー)へ戻し、修正後に該当レンズを再実施する。

## 原則

- **QA 完了 = 全レンズが 実施 or 理由付き skip、かつ finding がトリアージ済**。
  「一通り見ました」で終わらせない。
- push ゲートへの組み込みは現段階では行わない(明示起動のみ。安定後に self-review の
  条件スロット化を別途判断する — 将来注記)。
- ダイアログ(confirm/alert)を伴う操作は `browser_handle_dialog` で先に方針を決めてから
  踏む(ブロックしたまま固まる罠)。破壊的操作(削除・送信)は dev 環境であることを
  設定の base URL で確認してから実行する。
