---
name: evolve
description: >-
  ローカル進化の生成側。セッションの学びと外部脳(Guides/Mistakes/Decisions)から、
  skill/agent 化に値する知見を候補 skill として ~/.claude-evolution/candidates/ へ自動生成する。
  候補は有効化ゲート(/evolve-gate)を通るまで一切効力を持たない。
  「学びを skill 化」「候補を生成」「skill に昇華」、`/evolve` での起動、
  または evolve-nudge-on-stop hook のナッジで発火する。
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Skill
---

# evolve — ローカル進化の生成側

作業から得た学びを、マシンローカルの**候補 skill / 候補 agent** に蒸留して
`~/.claude-evolution/candidates/` へ書く。**生成は自動・有効化は人間ゲート**の前半を担う
(後半のトリアージと symlink 反映は姉妹スキル `evolve-gate`)。

## 不変条件(必読)

- **candidates は効力を持たない**。このスキルは symlink を張らない・`active/` に書かない・
  `~/.claude/skills|agents` に触れない。破ると「無検証の自動書込は採らない」原則
  (蓄積エンジン)が崩れる。
- **蓄積はマシンローカル**(`~/.claude-evolution` 固定・git 管理外)。業務知識を含んでよいが、
  git リポ(dotfiles / cc-dotfiles / 作業リポ)へこのスキルが書き込むことはない。
- **chezmoi 実体と同名の候補は生成禁止**(名前予約)。`~/.claude/skills/<name>`・
  `~/.claude/agents/<name>.md` が**実体(非 symlink)**で存在する名前は使わない。
  実体 skill の改善に気づいた場合は候補にせず「cc-dotfiles への手動反映推奨」として報告のみ
  (symlink 上書きによる実体破壊経路を生成側でも塞ぐ)。

## ディレクトリ規約(単一情報源)

```
~/.claude-evolution/
├── candidates/skills/<name>/SKILL.md   # 候補 skill(このスキルが書く)
├── candidates/agents/<name>.md         # 候補 agent(このスキルが書く)
├── active/skills/<name>/               # 承認済み(evolve-gate が mv、skills-sync が symlink)
├── active/agents/<name>.md             # 同上
└── rejected.txt                        # 破棄履歴(1 行 1 件: 日付\t名前\t理由)
```

ディレクトリは `mkdir -p` で遅延生成する。パスは固定(env override なし)。
消費者: evolve(生成)/ evolve-gate(トリアージ)/ evolve-nudge-on-stop hook(件数走査)/
dotfiles `bin/skills-sync.sh`(active の symlink 反映)。

## guide-capture との振り分け(学びの行き先)

同じ「学び」でも行き先が違う。迷ったらこの基準で振り分け、evolve の対象外は該当 skill を案内する:

| 学びの性質 | 行き先 |
|---|---|
| 運用知の現在状態(規約・注意点・落とし穴の「今こうする」) | `guide-capture` → 生きたガイド |
| **行動を変える再利用可能な手順・ワークフロー**(毎回同じ段取りで強制したい) | **evolve → 候補 skill** |
| 判断の履歴(なぜそう決めたか) | `obsidian-memory` → Decisions |
| ミスの観測ログ | `obsidian-memory` → Mistakes |

skill 化の品質バー(全て満たすものだけ候補にする):
**再利用可能**(次回も同じ手順を踏む)/ **非自明**(手順に落とさないと踏み外す)/
**手順として強制する価値がある**(ガイドの一文では守られない)。

## 手順

### 1. 学びの抽出

- 現セッションの作業から: 繰り返された指摘・修正のやり直し・新しく確立した段取り。
- 外部脳から(オンデマンド。全走査しない): 現在 repo の `Guides/<repo>/`、
  `Mistakes/<repo>/`・`Decisions/<repo>/` に、手順化されず繰り返し参照されている知見が
  あれば対象にする。

### 2. 重複チェック + 名前予約

候補名を決める前に走査する:

```bash
ls ~/.claude/skills/ ~/.claude/agents/ 2>/dev/null
ls ~/.claude-evolution/candidates/skills/ ~/.claude-evolution/candidates/agents/ \
   ~/.claude-evolution/active/skills/ ~/.claude-evolution/active/agents/ 2>/dev/null
cat ~/.claude-evolution/rejected.txt 2>/dev/null
```

- 既存(chezmoi 実体・ext-skills symlink・active・candidates)と**責務が重複**する候補は
  出さない。既存 **active** skill の改善は同名の候補として candidates に置く
  (evolve-gate が承認時に active を置換する「更新候補」)。
- `rejected.txt` にある名前・責務は再提案しない(人間が一度破棄した判断を蒸し返さない)。
- 名前予約(不変条件)に従い、実体と同名は避ける。

### 3. 候補の生成

- skill 定義の書式・品質は `prompt-craft` skill の定義生成モードに従う
  (未導入なら次の簡易基準で fail-open: frontmatter に name / description
  (自然文トリガ入り)/ 必要最小の allowed-tools、本文は手順を番号付きで、
  fail-open 箇所を明示、100 行以内)。
- 業務固有の情報(画面名・社内用語・NG 実例)は候補に**書いてよい**
  (マシンローカルで git に載らない前提。これがこの仕組みの存在理由)。
- agent 候補は「制約(ツール制限・隔離・読み取り専用)そのものが価値になる」場合のみ
  (専門化の原則)。手順で足りるものは skill にする。
- `candidates/skills/<name>/SKILL.md` または `candidates/agents/<name>.md` へ Write する。

### 4. 報告

生成した候補を一覧で報告し、有効化は人間の工程であることを明示する:

```text
## evolve 生成結果
| 候補 | 種別 | 1 行要旨 | 由来 |
|---|---|---|---|
| <name> | skill(新規/更新) | <要旨> | <セッション/ノート> |

候補は candidates/ 止まりで効力はありません。/evolve-gate でトリアージしてください。
```

- 生成ゼロ(品質バー不達)なら「候補なし(理由)」の 1 行で終わる。無理に作らない。
