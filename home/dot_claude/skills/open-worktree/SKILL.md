---
name: open-worktree
description: >-
  現在のセッションが作業中の Git worktree を tmux の縦・フル幅均等ペインで開く。
  どの worktree かは会話文脈から Claude が解決(POLICY)し、開き方は dotfiles の
  split-even.sh に委譲(MECHANISM)する薄いラッパ。`/open-worktree` での起動、
  「作業中の worktree を開いて」「worktree を tmux で見たい」等の自然文で発火する。
  tmux セッション内専用。
user-invocable: true
allowed-tools: Bash, Read, Grep, Glob, AskUserQuestion
---

# open-worktree

このセッションが作業中の Git worktree を tmux のフル幅均等ペイン(縦バンド)で開く。

## 手順

### 1. 対象 worktree の branch を特定する

現在の会話文脈から、このセッションが作業中の worktree の branch を割り出す
(直近に作成 or 作業した worktree)。明確なら自動選択する。**本当に曖昧な時
(複数案件を同時進行していてどれか判別できない時)だけ** AskUserQuestion で候補を
列挙して確認する。普段は聞き返さない。

### 2. worktree の絶対パスを導出する

優先順(副作用の無い手段を優先する):

1. **このセッションで既知のパス** — worktree 作成時に `wt.sh` が stdout に出した
   絶対パスがあればそれを使う(再導出不要)。
2. **不明なら読み取り専用で再導出** — 対象リポで `git worktree list --porcelain` を実行し、
   `worktree`/`branch` 行の対応から該当 branch の絶対パスを拾う(副作用なし。porcelain は
   出力形式が安定でパースに頑健)。
3. それでも見つからない時のみ `~/ghq/github.com/Hirayama61/dotfiles/bin/wt.sh <branch>`。
   既存 branch なら冪等にパスを返すが、**branch を取り違えると新規 worktree を作成する
   副作用がある**。branch が確実に存在する時だけ使い、不確かなら作成せずユーザーに確認する。

### 3. 開く

```bash
~/.claude/skills/open-worktree/open-worktree.sh <worktree-絶対パス>
```

均等化の機構は持たず dotfiles の `~/.config/tmux/split-even.sh v <path>` に委譲する
(薄いラッパ)。tmux 外で実行された / パスが不正 / split-even.sh 未配置の場合は
スクリプトがガードして非ゼロ終了する。

## 補足

- 開くペインは bare シェルで worktree に cd 済み。tig / nvim 等は手で起動する。
- tmux セッション内でのみ動く(`$TMUX` が空なら拒否される)。
