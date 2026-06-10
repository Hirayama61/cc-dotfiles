---
name: obsidian-harvest
description: >-
  外部脳(~/obsidian/brain)をリポジトリ単位で監査し、未符号化の知見と繰り返す誤挙動を
  hook / CLAUDE.md / settings / skill へ昇格させる改善計画を提案する。提案のみ・人間ゲート。
  「外部脳を収穫」「ハーベスト」「知見を config に昇格」「gap 監査」、`/obsidian-harvest`
  での起動で発火する。
user-invocable: true
allowed-tools: Bash, Read, Grep, Glob, Agent, AskUserQuestion
---

# obsidian-harvest

外部脳の gap-auditor。**documented gap**(脳に書かれたが未符号化の知見)と
**undocumented mistake**(まだ脳に無い、繰り返す誤挙動)の 2 トラックを delegate で検知し、
hook / CLAUDE.md / settings / skill·agent の 4 層へ昇格する改善計画と、Obsidian 整理の
4 アクションを提案する。`obsidian-memory`(書き)の対になる収穫/昇格(読み→config化)側。
**適用・commit・マーカー追記・新規起票は一切しない**(全て人間ゲート後の別工程)。

## 真の目的(必読)

**Claude Code の作業精度を上げ続ける仕組みを作り、それをチームに共有していく。**
脳は個人ローカルで共有されないため、学びは脳に閉じず「チームに伝播する成果物(対象リポに
commit する config)」まで届かせる。この目的が出力を **個人層 / チーム層** に二分する根拠
(§4 のルーティング)であり、汎用な学びの **越境昇格**(§4.3)を正当化する最上位制約。

## コンテキスト隔離の原則(必読)

self-review の同名節に倣う、このスキルの**品質の核となる不変条件**。必ず守る:

- 監査・反証は必ず **新規 Agent(delegate)** で起動する(メインの同一コンテキストで実行しない)。
- **メインは Obsidian 本文も config 実体も一切読まない**。delegate へ渡してよいのは
  「選択 repo キー + 作業ツリーパス + Vault パス(`~/obsidian/brain`)+ 検知トラック/シグナル源の指示」のみ。
- delegate が返すのは **構造化要約だけ**(§3 のスキーマ)。詳細な本文・候補の根拠は
  delegate が `~/obsidian/brain/Tasks/<repo>/` の成果物ファイルへ書く。
- 渡してはいけない: 実装意図・経緯・会話履歴・「この知見はこうだから昇格すべき」式の正当化。
  反証 delegate には監査 delegate の**判断理由を引き継がない**(候補 ID + 知見要約 + 想定層だけ渡す)。
- 狙い: コンテキスト効率最優先 +「深さはファイル、チャットは要約のみ」規約の遵守。
  メインが本文を読まないことで、提示まで一直線にコンテキストを保つ。

## delegate オーケストレーション

2 つの delegate を**直列**で起動する(B は A の出力に依存。並列化しない)。
どちらも**監査対象(config・既存ノート)を変更しない**読み取り専用の監査(自身の成果物
research.md / verify.md を `Tasks/` に書くだけ)なので **isolation は不要**(worktree 隔離は変更を伴う作業向け)。
`run_in_background` は任意だが、メインは各 delegate を待ってから次へ進む方が提示まで扱いやすい。

| # | delegate | スコープ | 入力 | 成果物書込先 | 返す構造化要約 |
|---|---|---|---|---|---|
| A | 監査 delegate | 選択 1 repo | repo キー・作業ツリーパス・Vault パス・検知トラック指示 | `~/obsidian/brain/Tasks/<repo>/YYYY-MM-DD-obsidian-harvest監査/research.md` | 候補リスト(§3.1) |
| B | 反証 delegate | A の候補のみ | A の候補リスト + 作業ツリーパス(config 実体) | 同上ディレクトリ `verify.md` | 各候補の survive/refute 判定(§3.2) |

- 実際の昇格適用(config 編集・マーカー追記・新規起票)は **このスキルの delegate に含めない**。
  人間承認後、メインが別途 delegate(config は `isolation:"worktree"`、Obsidian 起票は
  obsidian-memory)へ指示する別工程。スキルは提示で終了する(提案ゲート)。

### A・B が返す構造化要約スキーマ

メインのコンテキストを汚さないため、delegate は本文を Tasks の研究ファイルに書き、
**この表だけ**返す。

#### 監査 delegate A のスキーマ

```text
## 監査結果サマリー(repo: <repo>)
research.md: <絶対パス>
documented gap: N件 / undocumented mistake: M件

### 候補(documented gap + undocumented mistake 混在、ID 採番)
| ID | track | signal | 要約(知見) | 想定昇格層 | 根拠(ノート/シグナル) |
|---|---|---|---|---|---|
| H-001 | gap | brain | <1行> | hook | [[ノート名]] |
| H-002 | mistake | transcript | <1行> | rule | transcript: <要約> |
```

- `track` = `gap` / `mistake`。`signal` = `brain` / `review` / `transcript` / `git-churn` / `brain-churn`。
- `想定昇格層` = `hook` / `rule` / `settings` / `skill`(A の暫定分類。最終は手順 4 でメインが確定)。
- ID は `H-NNN`(3 桁ゼロ埋め、セッション内連番)。self-review の `F-NNN` に倣う。

#### 反証 delegate B のスキーマ

```text
## 反証結果(repo: <repo>)
verify.md: <絶対パス>

| ID | 判定 | 反証で見つけた既存符号化(あれば) |
|---|---|---|
| H-001 | survive | (config に該当なし。能動探索した場所: <列挙>) |
| H-002 | refute | 既に hook `block-foo.sh` で符号化済み → 計画から除外 |
```

- `判定` = `survive`(本当に未符号化 → 計画へ)/ `refute`(既に符号化済み → 除外、偽陽性)。
- `refute` には**どこに符号化済みか**を必ず書く(昇格済みマーカー追記の根拠にもなる)。

## 手順

### 1. repo 列挙 → 1 つ選択

`scripts/list-harvest-repos.sh` を実行し、外部脳に登録のある repo を列挙する
(read-only。Decisions/<repo>・Mistakes/<repo> のサブ名 + Knowledge/Projects の `project:`
frontmatter を OR 合算 → 一意化)。出力は 1 行 1 repo の `<repo>\t<作業ツリーパス or (no-worktree)>`。

```sh
"$HOME/.claude/skills/obsidian-harvest/scripts/list-harvest-repos.sh"
```

`AskUserQuestion` で 1 つに絞る(1 回の実行 = 選んだ 1 リポ)。選択肢ラベルに
**作業ツリー有/無**を添える(`(no-worktree)` の repo を選ぶと採掘シグナルが減ることを示す)。

- **作業ツリー無し**(`_shared`・論理プロジェクト `obsidian-memory`・未 clone)を選んだ場合:
  config 実体照合・git churn・transcript 採掘は**できない**ので、delegate A への指示で
  「**documented gap + brain churn のみ監査**(git churn / transcript はスキップ)」と明記する。
- repo キー → 作業ツリーパスはスクリプト出力の右列をそのまま使う(逆解決は
  `ghq list --full-path | grep -E "/<repo>$"`。`resolve-repo-key.sh` の逆)。

### 2. 監査 delegate A(検知 2 トラック × 4 シグナル源)

選択 repo について delegate A を 1 つ起動する。A が **Vault 本文と config 実体を読む**
(メインは読まない)。A への指示は次の 2 トラックを検知させ、§3.1 のスキーマだけ返させる。
本文・各候補の根拠は `~/obsidian/brain/Tasks/<repo>/YYYY-MM-DD-obsidian-harvest監査/research.md` へ書かせる。

**トラック①: documented gap(脳に書かれた知見 → 未符号化 delta)**

- 入力カテゴリ: `Decisions/<repo>/` + `Mistakes/<repo>/` + `Knowledge/`(gotcha のみ)。
  **除外**: `Projects/`(状態)/ `Tasks/`(作業ログ)/ `Preferences/`(既に Tier0・個人)。
- 各ノートの**知見 1 つ 1 つ**について「既に config に符号化済みか?」を照合(gap-audit。
  全ノート catalog 化はしない)。既に `## 外部脳候補` / 昇格済みマーカー callout(`[!done]`、§5.1)が
  付いているノートは **済みとして除外**(これが stateful・安価化の肝)。
- 照合先(層別): hook 系 → 作業ツリーの `home/dot_claude/hooks/`(個人=cc-dotfiles)or
  `.claude/hooks/`(チーム)/ rule 系 → global `~/.claude/CLAUDE.md`(cc-dotfiles 管理)or
  リポルート `CLAUDE.md` / settings 系 → cc-dotfiles `home/.chezmoidata.yaml` の
  `claude.permissions.*` ・ `settings.json.tmpl` / skill·agent 系 → `home/dot_claude/skills/`・`agents/`。
- **未符号化と判断した知見だけ**を候補 `H-NNN`(track=gap)として残す。

**トラック②: undocumented mistake 採掘(まだ脳に無い、繰り返す誤挙動)**

4 シグナル源から「繰り返す誤挙動」を採掘する(機構は §2 末の注記参照)。

1. **transcript**: `~/.claude/projects/<sanitized-cwd>/*.jsonl` の
   直近 ~50 を走査。sanitized-cwd = 作業ツリー絶対パスの `/`→`-` 化(例
   `-Users-h61-ghq-github-com-Hirayama61-cc-dotfiles`)。採掘対象は
   「**ユーザーからの訂正・やり直し・同種エラーの反復**」を拾う。具体シグナル =
   ユーザー turn の訂正語(「違う」「そうじゃない」「やめて」「訂正」「またそれ」)、
   同一 tool_use の失敗 → 再試行ループ、`Edit` の取り消し・revert 連鎖。
2. **レビュー指摘の履歴**: self-review / CodeRabbit / Codex の指摘が transcript に残る。
   同種カテゴリ(`[security]` / `[quality]` 等)が**複数回**出ている repo 固有パターンで、
   過去の `Mistakes/<repo>/` に未起票のもの。
3. **git churn**: 作業ツリーで `git log --oneline -50` + `git log -p --follow <churn 候補>` を見て、
   **同一ファイル/同一行の往復改変**(足して消す・revert)や「直後の fix コミット」が多い箇所。
4. **脳の churn**: `Mistakes/<repo>/` に**同主題が複数**溜まっている(=反復が脳に観測されているのに
   未昇華)。「複数ミスが 1 つの防止ルールに集約できる」兆候として hook/rule 昇格候補にする。

- 採掘した誤挙動を候補 `H-NNN`(track=mistake, signal=該当源)として残す。②は **新規 Mistakes 起票**
  (脳がまだ知らないもの)と **昇格(防止ルール提案)** の両方を生む → 手順 4 と手順 5 のアクション③に流れる。

> [!note] transcript 採掘の範囲(MVP)
> 初期実装は **main clone の sanitized-cwd の transcript のみ**採掘する。worktree 作業分は
> 別 sanitized-cwd(`-Users-h61-worktrees-...`)に散るが、**横断採掘は将来拡張**とし、現状は
> その限界を受容する(lean に始め、必要になったら拡張)。

### 3. 反証パス delegate B(adversarial verify)

A の「未符号化(survive 候補)」を独立 delegate B が**能動反証**する。偽陽性(=済みの再提案、
このスキルが最も嫌う事象)を構造的に潰す。B のスコープは **A の候補リストのみ**(Vault 全体は
再走査しない=コスト局所化)。

各候補 `H-NNN` について「**本当に config に無いか**」を能動的に探させる:

- 想定昇格層と**別の層**も含めて横断 grep する(hook に無くても rule や skill に既にあるかもしれない)。
  探索範囲: cc-dotfiles 全体 + global `~/.claude/CLAUDE.md` + 選択 repo の `.claude/`・`CLAUDE.md`。
- **存在を見つけたら `refute`**(どこに符号化済みかを必ず記録 → 昇格済みマーカー追記の根拠に転用)。
- 見つからなければ `survive` → 計画へ。
- B には A の**判断理由を引き継がない**(候補 ID + 知見要約 + 想定層だけ渡す。self-review の
  「実装意図を渡さない」隔離思想の転用)。

### 4. 4 層分類 + 選択リポ基準ルーティング

survive した候補だけを 4 層へ分類し、選択リポ基準で昇格先を決める。

#### 4 層の判定基準

| 層 | 判定基準 | 個人層の実体(cc-dotfiles) | チーム層の実体(対象 repo) |
|---|---|---|---|
| **hook** | 機械的に**強制**できる(PreToolUse/PostToolUse 等で検出・ブロック可能) | `home/dot_claude/hooks/private_executable_*.sh` | `<repo>/.claude/hooks/` + settings.json の hook 登録 |
| **CLAUDE.md(rule)** | 強制不能で**判断・規律**として書くべき(hook で守れない挙動の核) | global `~/.claude/CLAUDE.md`(cc-dotfiles 管理) | `<repo>/CLAUDE.md` |
| **settings.json** | 許可リスト・env・hook 登録など宣言的設定 | `home/.chezmoidata.yaml` + `settings.json.tmpl` | `<repo>/.claude/settings.json` |
| **skill·agent** | 手順化された再利用ワークフロー・専門エージェント | `home/dot_claude/skills/`・`agents/` | `<repo>/.claude/skills/`・`agents/` |

- **hook vs rule の境界 = 既存規約を流用**:「hook で守れる事項は CLAUDE.md に書かない」
  (global CLAUDE.md 冒頭の規約)。機械チェック可能なら hook、判断を要するなら rule。
  hook/CLAUDE.md が主軸、settings/skill は従。

#### 選択リポ基準ルーティング(選択がルーティング)

- 選択 repo が **dotfiles / cc-dotfiles** → **個人層**(global `~/.claude`・personal hook/settings)。
- 選択 repo が **それ以外のプロジェクトリポ**(GitHub owner 有り)→ **チーム層** = そのリポの
  `.claude/`・`CLAUDE.md` に commit(git で全員に伝播)。
- 選択 repo が **ghq `local/` のリポ**(GitHub owner 無し = ローカル専用)→ **個人/ローカル扱い**で
  そのリポの repo-local config に昇格。提示時に「**git 伝播は無い(ローカル限定)**」と明示する。
- 別途の個人/チーム分類器は不要。「リポジトリに反映するかしないか」が基準。
- **昇格先ファイルの自動提案 + ゲート確認**: 個人層の実体は複数リポに跨る(hook/settings/skill/agent/
  global CLAUDE.md = cc-dotfiles、端末・開発環境のプロジェクト CLAUDE.md = dotfiles)。スキルは
  **層 × 内容で昇格先ファイルを自動推定して提案**し、人間が承認ゲートで最終確認する
  (hook→cc-dotfiles 固定、global rule→cc-dotfiles、repo 固有 rule→その repo)。**mid-run の追加質問はしない。**

#### 越境昇格(cross-pollination・双方向)

- 選択 repo で見つけた**汎用的(リポ固有でない)学び** → 選択先でなく**個人層 global** へ越境推奨。
- 逆に **global ルールがリポ固有** → そのリポへ押し下げ推奨。
- 越境条件 = 「その知見が選択 repo に閉じるか、全 repo に効くか」。閉じないなら越境。
- 越境は**推奨提示に留める**(最終判断は人間。提案のみゲート。真の目的「全 repo で精度向上」を最大化)。

### 5. 提案提示(改善計画 + Obsidian 整理 4 アクション)

メインは delegate の構造化要約のみで以下を組み立てる(**本文は読まない**)。self-review の
3 部構成(サマリー + サブテーブル + 総評)に倣う。Obsidian 整理は全て**非破壊・提案ベース**で、
適用は人間承認後に obsidian-memory / delegate が実行する(スキルは案を出すだけ)。

```text
## 収穫サマリー(repo: <repo> / 昇格先: 個人層|チーム層)
監査 N件 → 反証 survive M件 → 計画 M件 / Obsidian 整理 K件
research.md: <パス> / verify.md: <パス>

### 改善計画(survive した昇格候補・優先度順)
| ID | 層 | 越境 | 昇格先 | 概要 | 根拠 | 判断 |
|---|---|---|---|---|---|---|
| H-001 | hook | - | cc-dotfiles hooks/ | <1行> | [[ノート]] | 推奨：再発防止に直結 |
| H-002 | rule | global越境 | ~/.claude/CLAUDE.md | <1行> | transcript反復 | 任意：頻度低め |

### Obsidian 整理(4 アクション)
| ID | アクション | 対象ノート | 内容 | 判断 |
|---|---|---|---|---|
| O-001 | ①昇格済みマーカー | [[ノート]] | [!done] callout 追記 | 推奨 |
| O-002 | ②陳腐化訂正 | [[ノート]] | [!warning] callout | 推奨：現configと矛盾 |
| O-003 | ③新規起票 | (新規) Mistakes/<repo>/... | mining由来 | 任意 |

### 総評
<昇格の費用対効果・越境推奨の有無・次アクション(適用は人間承認後に別工程へ委譲)>
```

- 「判断」列は self-review の `語：理由` 形式(`必須/推奨/任意/見送り可：理由`)で**全件に理由を併記**。右端固定。
- ID 体系: 昇格候補 `H-NNN`、Obsidian 整理 `O-NNN`(セッション内連番)。指摘ゼロのセクションは `(なし)` の 1 行。
- **適用はしない**: 提示後、人間が承認した分だけメインが別 delegate(config は `isolation:"worktree"`、
  Obsidian 起票は obsidian-memory)へ指示する。スキルはここで終了する(提案ゲート)。

## Obsidian 整理 4 アクションのフォーマット

**全て非破壊・提案ベース**。スキルは案を出すだけ。記法の正確さは `obsidian-markdown` skill に従う
(wikilink は bare basename / callout 構文)。

### アクション①: 昇格済みマーカー(元ノートへ非破壊 callout 追記)

昇格した documented-gap の**元ノート**へ、原文を消さず末尾 callout を追記する案を出す:

```markdown
> [!done] 昇格済み 2026-06-04
> この知見は **hook `block-foo.sh`**(個人層・cc-dotfiles)で符号化済み。
> 関連: [[2026-06-04-obsidian-harvest監査]]
```

- `[!done]` を「符号化済み」マーカー種別に**固定**(既存 vault は `[!note]/[!warning]/[!important]` 使用。
  `[!done]` は未使用=衝突せず意味が明快)。1 行目に `昇格済み YYYY-MM-DD`、本文に昇格先と層を明記。
- これが次回監査の「済み」判定の根拠(手順 2 トラック①)= gap-auditor を stateful・安価にする
  フィードバック機構(ループの肝)。

### アクション②: 陳腐化訂正(現 config と矛盾する古いノート)

現 config と**矛盾**する古いノートには、原文を残し非破壊 callout を追記する案(削除しない):

```markdown
> [!warning] 2026-06-04 時点で陳腐化
> 現 config では X でなく Y が正(hook `bar.sh` 参照)。原文は履歴として保持。
```

- delegate がこの陳腐化を見つけたら**初回報告で flag**する(delegate 規約の鮮度メンテ)。
- 大きな矛盾は callout でなく**人間申告に留める**選択肢も提示(破壊度が高い訂正はエスカレーション)。

### アクション③: 新規 Mistakes/Knowledge 起票(mining 由来)

undocumented mistake 採掘(手順 2 トラック②)で「脳がまだ知らない」ものを新規起票する案:

- 配置・命名・frontmatter は **obsidian-memory の作法に厳密に従う**(再定義しない):
  - Mistakes → `Mistakes/<repo>/YYYY-MM-DD-日本語トピック.md`(並列衝突しうるなら `-HHMMSS-`)。
  - Knowledge(gotcha) → flat `Knowledge/日本語トピック.md`。
  - frontmatter は obsidian-memory テンプレ(`templates/mistake.md` / `knowledge.md`)使用。
- 起票は**人間承認後に obsidian-memory(Skill)経由**でメイン or delegate が書く(このスキルは案のみ)。
- ファイル名は **NFC 統一**(macOS 罠。obsidian-memory §3 注記)。

### アクション④: 統合・tag 修正 hygiene

- 重複ノートの統合候補・tag ゆれ・孤立(無リンク)ノートへの wikilink 追加を**提案列挙のみ**。
- 破壊的操作(Edit 上書き・統合)はしない。人間判断材料として列挙する。

## 原則 / 将来

- **偽陽性(=済みの再提案)が最も嫌うもの**。反証パス(手順 3)で潰し、昇格済みマーカー(①)で
  stateful 監査の肝とする。この 2 つが「再提案ループ」を構造的に防ぐ。
- **越境昇格は真の目的の最大化**(全 repo で精度向上)。汎用な学びを個人層 global へ押し上げる。
- **提案のみ = config は影響大**なので、プランレビューゲート & 作業前エスカレーション規約に従う
  (`allowed-tools` に Write/Edit を入れていないのはこの不変条件の現れ)。
- このスキルは **意図して定期的に回す前提**(自動 hook / scheduled ではない)。
  昇格済みマーカーが溜まるほど次回の監査が安価になる。
