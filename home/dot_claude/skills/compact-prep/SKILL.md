---
name: compact-prep
description: >-
  /compact の前に、圧縮の要約に載りきらない判断構造とセッション状態を state file へ
  固定フォーマットで退避する。コンテキスト使用率 30% の提案注入・50% の最終通告・
  precompact-gate のブロック時、「compact の準備」「state file を書いて」、
  `/compact-prep` での起動で発火する。書き終えたら人間に /compact の実行を依頼する。
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Agent
---

# compact-prep — 圧縮前の判断構造退避

compact の LLM 要約は「何をやったか」の物語になり、「なぜその選択をしたか・どの案を
却下したか・今どのフェーズか」が薄まる。この skill はその失われる部分だけを
state file に退避する。設計の正典は Decisions ノート
`2026-07-22-コンテキスト逼迫対策をcompact正で設計`(cc-dotfiles)。

## 0. パス導出

```sh
ctx="$("$HOME/.claude/hooks/lib/context-paths.sh" key "<現セッションの transcript_path>")"
"$HOME/.claude/hooks/lib/context-paths.sh" ensure "$ctx"
state="$("$HOME/.claude/hooks/lib/context-paths.sh" state "$ctx")"
decisions="$("$HOME/.claude/hooks/lib/context-paths.sh" decisions "$ctx")"
```

transcript_path が分からない場合は書かない(推測名でファイルを作らない。hard gate)。
statusline が書く usage.json(`context-paths.sh usage "$ctx"`)の transcript_path と
一致していることを確認してから進む。

## 1. モード分岐(最初に必ず判定)

- **state file が既に存在する** → **差分追記モード**(手順 3)。フル生成し直さない。
  50% 超の劣化した状態で全量整理をやり直さない、がこの skill の設計の核。
- **state file が無い** → **フル生成モード**(手順 2)。30%(提案ライン)での実行が前提。

## 2. フル生成モード

`$decisions`(決定ログ: 人間発話の逐語 / 承認 plan / Q&A)を**全量 Read** し、
次の **5 見出し固定・この順**で `$state` に書く。

```markdown
# state file

## Active Plan
(plan ファイルのパスと現在フェーズ。plan が無ければ「なし」)

## Session Decisions
(採用した案 / 却下した案 / 却下した理由。決定ログの qa・plan と会話中の合意の両方から)

## Constraints and Blockers
(セッション中に確立した制約・原則・ブロッカー。「〜してはいけない」「〜が前提」)

## Worker Topology
(稼働中の subagent / tmux pane / worktree とその担当。無ければ「なし」)

## Editing Files
(編集途中・未保存・未検証のファイルと残作業。無ければ「なし」)
```

規律:

- 書くのは「圧縮で失われ、かつ他のどこにも残らないもの」= **why と現在位置**だけ。
  コードに残ること・TaskList にあること・決定ログの生データの写しは書かない。
- 各節は必ず非空(該当なしなら「なし」と書く)。自由記述の追加見出しは作らない。

## 3. 差分追記モード

既存 `$state` を Read し、前回書き出し以降に変わった点だけを該当見出しの下へ追記する:

- 決定ログの末尾(前回以降の turn)に現れた新しい判断 → Session Decisions へ追記
- フェーズ・作業対象の変化 → Active Plan / Editing Files を更新
- 全文の書き直し・再構成はしない

## 4. 構造検証(必須)

```sh
bash "$HOME/.claude/skills/compact-prep/scripts/validate-state.sh" "$state"
```

FAIL なら不足見出し・空の節を直してから再実行。PASS するまで手順 5 へ進まない。

## 5. 決定ログ突合(必須)

`$decisions` の各エントリ(特に type: qa と、発話中の指示・訂正・却下)について
「state file にその判断が反映されているか」を確認し、漏れを Session Decisions へ足す。
機械記録(決定ログ)が骨格、state file が肉付けという関係 — 骨格に無い肉はよいが、
骨格にある判断が state file から欠けるのは欠落。

## 6. 独立検証(使用率 50% 超のときのみ)

usage.json の pct が 50 以上なら、`delegate` Agent に `$state` と `$decisions` の
パスを渡し「この 2 ファイルだけで作業を再開するとき、何が分からないか」を挙げさせ、
指摘を state file に反映する(劣化した自分の自己採点で終えない)。50% 未満なら省略。

## 7. 人間へ /compact を依頼

state file 完成後、人間に /compact の実行を依頼する。`/compact` を pbcopy に入れ、
「クリップボードに入れた」と一言添える(実行コマンドの渡し方の Preference に従う)。
/compact 後の復帰は hook(postcompact-marker → context-pressure-notify)が自動で
面倒を見るので、この skill の仕事はここまで。
