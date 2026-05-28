---
name: self-review
description: >-
  push 前の汎用品質レビュー隊。push 対象 diff を code-reviewer・security-reviewer
  の 2 Agent + CodeRabbit CLI で並列検査し、severity 順に人間へ提示してトリアージを
  促す。「セルフレビューして」「push 前に確認」、`/self-review [effort]` での起動、
  またはオーケストレータが push 直前に実行する。レビュー実施 + 人間トリアージ
  済を確認した時だけ push ゲートのフラグを立てる。指摘ゼロは強制しない。
user-invocable: true
allowed-tools: Bash, Read, Grep, Glob, Agent, AskUserQuestion
---

# self-review

push 前の汎用レビュー隊。code-reviewer / security-reviewer の 2 Agent と
CodeRabbit CLI を**並列**で走らせ、指摘を 3 段階(重大/改善/情報)に正規化・統合し、
人間がトリアージできる状態にして push を解禁する。

## コンテキスト隔離の原則(必読)

VCSDD の Adversary 設計に倣い、reviewer には**コンテキスト隔離**を徹底する。
これがこのスキルの品質の核なので必ず守る:

- reviewer は必ず**新規 Agent**で起動する(同一コンテキストで実行しない)。
- reviewer に渡してよいのは **差分 + 変更ファイル一覧 + 対象 repo の CLAUDE.md
  コーディング規約のみ**。
- 渡してはいけない: 実装意図・経緯・会話履歴・「この変更は〇〇のため」式の正当化。
- 狙い: 「エントロピー抵抗の欠如」(会話が長いほど AI が正当化する傾向)を構造的に
  排除し、コードの品質だけで判断させる。

## 手順

### 1. 対象 diff の特定

- `git branch --show-current` で現在ブランチを確認。
- 保護ブランチ(`main`/`master`/`develop`/`epic/*`)上では gate 自体が無効
  (`pre-push-selfreview-gate.sh` が除外)なので、**このスキルの対象外として
  早期 return する**(フラグも立てない)。
- push 対象は「未 push コミット + 作業ツリー変更」。base ref は ①upstream 追跡が
  あれば `@{u}` ②無ければデフォルトブランチ(`main`/`master`)で決める。
- `git diff <base>...HEAD`(三点記法)+ `git diff` で全体差分を取得。
- `git diff --name-only <base>...HEAD` で変更ファイル一覧を取得。
- 対象 repo のコーディング規約(リポルートの `CLAUDE.md` のコーディング規約節)が
  あれば読み、reviewer に渡す材料として手元に置く。

### 2. reviewer 群を 1 レスポンスで並列起動

**同一アシスタントターン(1 レスポンス)の中で**、以下の 2 Agent と CodeRabbit CLI を
**まとめて**発火する(逐次にしない)。各 reviewer には上記「コンテキスト隔離の原則」
どおり差分 + 変更ファイル一覧 + コーディング規約のみを渡す。

- `Agent(subagent_type: "code-reviewer")` — 品質・保守性・パフォーマンス +
  AI スロップを検査。**effort をプロンプト引数として渡す**(`/self-review [effort]`
  の effort、未指定なら medium 相当。code-reviewer 本文の effort スケールに従う)。
- `Agent(subagent_type: "security-reviewer")` — OWASP Top 10 ベースの脆弱性検査。
  effort は渡さない(security は常に網羅)。
- CodeRabbit は **Bash で CLI を直叩き**する(Agent / skill を経由しない。
  名前衝突の根を断つため CLI 固定):
  ```bash
  if command -v coderabbit >/dev/null 2>&1; then
    coderabbit review --agent --base "${base_ref}" -t committed
  else
    echo "CodeRabbit: skip(未導入)"
  fi
  ```
  未導入・未認証・ネットワーク不可なら `CodeRabbit: skip(理由)` と明示して続行する
  (**ブロックしない**)。`base_ref` には手順 1 で決めた base ref を設定してから呼ぶ。

全 reviewer(2 Agent + CLI)の完了を待ってから次へ進む。

> [!note] 将来の並列スロット(P2 完了後)
> P2(外部脳ハイブリッド再編)完了後、ここに **obsidian-reviewer**(差分を過去
> Decision / Mistakes / Knowledge gotcha と照合する Agent)を 3 つ目の並列スロット
> として追加する予定。現時点では obsidian-reviewer の実体 Agent は存在しないため
> **起動しない**(存在しない subagent_type を Agent 起動すると壊れる)。今回実際に
> 並列起動するのは code-reviewer・security-reviewer の 2 Agent + CodeRabbit CLI のみ。

### 3. 結果統合と優先度付け

全 reviewer の指摘を 3 段階(重大/改善/情報)へ正規化して統合する。

severity 正規化対応表(各 reviewer の語彙がばらつくため統合層でマップする):

| reviewer の語彙 | 統合 severity |
|---|---|
| Critical / High | 重大 |
| Major / Medium | 改善 |
| Minor / Low | 情報 |
| AI スロップ(構造的/ロジック/テスト) | 重大 |
| CodeRabbit の critical/error | 重大 |
| CodeRabbit の warning/suggestion | 改善 |
| CodeRabbit の nit/info | 情報 |

統合ルール:

- 重複指摘(複数 reviewer が同じ問題)は 1 つにまとめ、**指摘元を併記**する。
- 矛盾する指摘は両論併記し、判断材料を提示する。
- Finding ID(`F-NNN`、3 桁ゼロ埋め、セッション内連番)を**重大・改善・情報すべて**に
  採番する。番号は **重大 → 改善 → 情報 の順に通し連番**で振る。
- カテゴリタグ: `[security]` `[quality]` `[perf]` `[test]` `[slop]` `[arch]`
  (将来 `[obsidian]` を追加)。

#### 判断(統合層が各 finding に付与する正規語彙)

severity(重大/改善/情報)は reviewer 由来の「問題の深刻度」だが、それとは**独立**に、
統合層が各 finding に **判断**(Claude が文脈込みで薦める対応)を 1 つ必ず付ける。
判断は severity に縛られない(例: reviewer が重大と上げても、誤検知/許容と判断すれば
「見送り可」になり得る)。表記は `語：理由` 形式で、**全判断に理由を必ず併記**する。
理由はその判断に至った要点(問題の核心・対応方針・許容理由のいずれか)を簡潔に書く。

- `必須：理由` … push 前に今すぐ修正すべき(blocker)。
- `推奨：理由` … 直すべきだが blocker ではない。
- `任意：理由` … 好み・余裕があれば。
- `見送り可：理由` … 誤検知/許容で対応不要。

### 4. 人間へのフィードバック提示

severity 順(重大 → 改善 → 情報)に提示する。フィードバック原則:

- 根拠のない賛辞は禁止(「良いコードですね」等)。
- 全ての指摘に具体的な根拠を付ける(「なぜ問題か」)。
- 重大・改善には「どう修正するか」をセットで示す(可能ならコードスニペット)。
  ただしテーブル本体には出さず、オンデマンド詳細で出す(下記)。
- 不明点は「確認が必要」と正直に記載する。

提示は **サマリーヘッダー + severity ごとのサブテーブル + 総評** の 3 部構成。
修正例・コードスニペットはテーブルに出さず(件数が増えると見切れる)、ユーザーが
ID を指定したときにフル詳細をオンデマンドで出す。

提示フォーマット(目安):

```text
## レビュー結果サマリー
対象: {ブランチ} / 変更 {N} ファイル
重大 {N} / 改善 {N} / 情報 {N}
reviewer: code-reviewer / security-reviewer / CodeRabbit({実施 or skip 理由})

### 重大
| ID | cat | 場所 | 概要 | 判断 |
|---|---|---|---|---|
| F-001 | [security] | {ファイル}:{行} | {1 行要約} | 必須：任意コード実行に直結 |

### 改善
| ID | cat | 場所 | 概要 | 判断 |
|---|---|---|---|---|
| F-00N | [quality] | {ファイル}:{行} | {1 行要約} | 推奨：{理由} |

### 情報
| ID | cat | 場所 | 概要 | 判断 |
|---|---|---|---|---|
| F-00N | [perf] | {ファイル}:{行} | {1 行要約} | 任意：{理由} |

### 総評
{全体評価と push 推奨可否(最終可否は人間トリアージ)・次のアクション}
```

テーブルの規約:

- 列は `| ID | cat | 場所 | 概要 | 判断 |`。「判断」は**右端**に置き、`語：理由` 形式
  (例 `必須：任意コード実行に直結`)。
- 「場所」は `ファイル:行`、「概要」は 1 行要約。
- 指摘元(reviewer)列はテーブルに**出さない**(オンデマンド詳細にのみ表示)。
- 指摘ゼロの severity は、そのセクションの本文を `(なし)` の 1 行にする(テーブルは省く)。
- 通し連番は採番対象の finding に順に振り、欠番は作らない(指摘ゼロの severity が
  あっても番号は詰める。例: 重大ゼロなら改善の先頭が F-001)。
- テーブル群のあとに**ヒント行は置かない**(「ID を指定すれば…」等は書かない)。総評のみ。

#### オンデマンド詳細(ユーザーが ID を指定したとき)

ユーザーが `F-001` のように ID を指定したら、その finding の**フル詳細**を出す
(問題 + 指摘元 + 修正例)。複数 reviewer が同じ問題を上げていれば指摘元を併記する。

```text
#### F-001 [security] {概要}
ファイル: {パス}:{行} / 指摘元: {reviewer}(複数なら併記)
問題: {なぜ問題か}
修正例:
{コードスニペット}
```

### 5. 判定とゲートフラグ

- 通過条件は「レビュー実施 + 人間がトリアージ済(修正 or 意図的見送り)」。
  **指摘ゼロは強制しない。**
- トリアージ完了を確認したらフラグを立てる(`pre-push-selfreview-gate.sh`(読取)/
  `postcommit-invalidate-review.sh`(削除)とキー規約 `review-passed-${repo}--${safe}`
  を完全一致させる。repo は `resolve-repo-key.sh` で導出。3者の1つでも崩すと恒久
  ブロック or ゲート無効化になるので hook 側と必ず同時に変更する。
  **このスキルはレビュー対象 repo 内(`$PWD` = 対象 worktree)で実行すること**。gate /
  postcommit はフラグキーを push 実対象 dir(`git -C`/`cd` 解決)起点で引くため、別 cwd
  で実行するとキー基点がずれて恒久ブロックになりうる):
  ```sh
  branch="$(git branch --show-current)"
  safe="$(echo "$branch" | tr '/' '-')"
  repo="$("$HOME/.claude/hooks/lib/resolve-repo-key.sh" "$PWD" 2>/dev/null || true)"
  mkdir -p /tmp/claude-sessions
  touch "/tmp/claude-sessions/review-passed-${repo}--${safe}"
  ```
  これで `pre-push-selfreview-gate.sh` が解除される。
- レビュー未実施・トリアージ未了ならフラグを書かない。

## 原則

- フラグは「現在の HEAD をレビュー済」の意味。`git commit` 後は
  `postcommit-invalidate-review.sh` がフラグを無効化するので、新規コミット後は
  再レビュー必須。
- 保護ブランチ(`main`/`master`/`develop`/`epic/*`)では gate が無効。push/merge
  の可否判断は `block-protected-branch-push.sh` と人間判断に委ねる。
- CodeRabbit は **CLI 専用に固定**(`coderabbit review --agent --base <base>
  -t committed`)。公式プラグインの skill(`coderabbit:code-review` 等)は
  このスキルからは呼ばない(bare 名衝突の根を断つ)。CLI の前提は
  `coderabbit auth login`。
