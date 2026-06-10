---
name: guide-to-repo
description: >-
  vault の生きたガイド(~/obsidian/brain/Guides)の安定・共有可能な部分を対象 repo の
  AGENTS.md へ diff 承認(人間ゲート)付きで投影する。`/guide-to-repo`・「ガイドをリポに反映」等で起動する。
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, AskUserQuestion
user-invocable: true
---

# guide-to-repo

vault の生きたガイド(`~/obsidian/brain/Guides`)の**安定・共有可能な部分だけ**を
抜粋し、対象 repo の `AGENTS.md` に**一方向・オンデマンド・diff ゲート付き**で投影する。

**vault が source of truth。** `AGENTS.md` は派生物であり、双方向同期はしない。
ガイドを更新したい時は vault 側(`guide-capture`)を使い、`AGENTS.md` 直接編集は
しない(次回の `guide-to-repo` 実行で上書きされる)。

**なぜ `AGENTS.md` か。**
`inject-coding-standards.sh` が編集時に `AGENTS.md` を Claude のコンテキストへ先頭注入する。
これにより**メイン会話を持たない delegate / 独立コンテキストの Claude にも運用知が届く**
(グローバル規約の補強)。`AGENTS.md` は version 管理 + 人間/CI 可視でもある。

---

## 1. 対象 context を解決する

```sh
~/.claude/hooks/lib/resolve-repo-key.sh "$PWD"
```

- 返り値が **repo キー**(例 `dotfiles` / `cc-dotfiles`)なら → `Guides/<repo>/` を対象にする。
- **空文字**が返る(非 git 文脈)なら → 人間に「どの repo に反映しますか?」と確認してから進む
  (誤った AGENTS.md に書かない)。

## 2. ガイドを読む

対象 context のルートガイドを読む:

```
~/obsidian/brain/Guides/<repo>/<repo>-ガイド.md
```

ルートガイドが無ければ「反映するガイドがまだありません。`guide-capture` で作成してください」
と伝えて**止まる**(空の AGENTS.md セクションを作らない)。

ルートガイドの `related:` や本文中の `[[link]]` でサブ doc が参照されていれば、
それも Read して全体像を把握する(サブ doc の内容も抜粋対象になりうる)。

## 3. 安定・共有可能な部分を抜粋する(切り抜き)

ガイド全文をコピーするのでなく、**repo を触る人(や delegate)が従うべき確立した部分だけ**
を選ぶ。

**含める:**
- 確立したテスト規約・実装規約・コマンド手順。
- 落とし穴・注意点(再発防止になるもの)。
- アーキテクチャの前提(知らないと壊す系)。

**除外する:**
- 「検討中」「暫定」「要確認」等の**半生/未確定**の記述。
- 個人メモ・private な文脈(他者に無意味 or 公開リポに不適)。
- vault 固有の文脈(Obsidian 操作、外部脳の使い方など — repo 作業に関係しない)。
- `guide-capture` / `guide-to-repo` 自体の運用メモ(メタ情報を AGENTS.md に混ぜない)。
- `_topics/` のハブノード内容で当該 repo に関係しない横断知。

抜粋判断が曖昧な場合は、**「含める / 除外する」を理由付きで提示**して人間に確認する
(§5 の diff 提示で行う)。

## 4. AGENTS.md 形式へ変換する

抜粋した内容を repo ファイル向けの形式へ変換する。

### wikilink のプレーンテキスト化

vault 固有の `[[wikilink]]` は AGENTS.md(vault グラフ外)では機能しない。
以下のルールで変換する:

- `[[bare名]]` — **bare 名をそのままプレーンテキスト**に(例: `[[dotfiles-ガイド]]` → `dotfiles-ガイド`)。
- `[[bare名|エイリアス]]` — **エイリアス部分のみ**残す。
- サブ doc への `[[link]]` — サブ doc の内容を既に抜粋に含めているなら link は不要なので削除。
  含めていないなら link 自体を除去し、必要な情報は本文から直接抜粋する。

### 生成セクションマーカー(冪等置換の要)

AGENTS.md のうち **生成セクション**(`<!-- BEGIN: living-guide (generated) -->` 〜
`<!-- END: living-guide -->` で囲まれた範囲)にだけ書く。

- **既存 AGENTS.md に該当セクションがある** → セクション内を丸ごと置換。マーカー外の
  人手記述は一切触れない。
- **既存 AGENTS.md にセクションが無い** → ファイル末尾にセクションを追記する
  (既存内容の後ろに改行を挟んで追加)。
- **AGENTS.md 自体が無い** → 新規作成し、ヘッダ + セクションだけで構成する(§8 の雛形)。

セクション内の**冒頭に必ず以下の注記を入れる**(セクション冒頭固定):

```
> [!note] このセクションは vault の生きたガイドから派生・`guide-to-repo` で生成。
> 直接編集せず、Obsidian 側のガイド(`guide-capture`)を更新してこのコマンドを再実行すること。
```

## 5. diff 提示 → 人間承認 → 書込

**書込前に必ず変更を diff で見せ、承認を得てから書く。** これがこのスキルの安全弁。

提示時に明示するもの:
1. **変更の種類**: 新規作成 / セクション追加 / セクション置換。
2. **抜粋の根拠**: 含めたもの・除外したものとその理由を簡潔に。
3. **人手セクションの保全確認**: 既存 AGENTS.md がある場合は「マーカー外の XX 行は変更しません」
   と明示する(人間が確認しやすくする)。

重要な二者択一(「このトピックは含めますか?」等)は `AskUserQuestion` を使い、
**必ず推奨案を添える**。

承認後に Edit(既存ファイルの場合)/ Write(新規の場合)で書く。
承認が得られない/曖昧なら書かない。

## 6. 書込先の注意

`AGENTS.md` は doc-gravity の**許可リスト**(`block-repo-doc.sh` の `allowed_filenames` に
`AGENTS.md` が含まれる)なので、Write/Edit はブロックされない。

ただし **block-main-clone-edit** が有効な場合、メイン clone(例 `~/ghq/...`)上の
ファイルへの書込はブロックされうる。その場合は:
- 対象 repo の worktree(`~/worktrees/...`)上で作業する。
- メイン clone と worktree の区別は `git rev-parse --show-toplevel` で確認できる。

## 7. 報告(サイレント禁止)

書いたら必ず明示する:

- `Obsidian→repo: <repo>/AGENTS.md の living-guide セクションを新規作成しました`
- `Obsidian→repo: <repo>/AGENTS.md の living-guide セクションを更新しました`

変更なし(ガイドと AGENTS.md が同一内容)の場合も「変更なし」と報告する(無言で終わらない)。

## 8. AGENTS.md の最小雛形(新規作成時)

`<repo>` を実際のリポ名に置換して書く。

```markdown
# AGENTS.md

このリポジトリで Claude(および他の AI エージェント)が従うべき規約をまとめる。

<!-- BEGIN: living-guide (generated) -->
> [!note] このセクションは vault の生きたガイドから派生・`guide-to-repo` で生成。
> 直接編集せず、Obsidian 側のガイド(`guide-capture`)を更新してこのコマンドを再実行すること。

<!-- ここに抜粋した内容が入る -->

<!-- END: living-guide -->
```

## 9. 規約

- **一方向のみ**: `AGENTS.md` → vault への逆流は行わない。誤りを見つけた時は
  vault 側を `guide-capture` で修正し、その後 `guide-to-repo` で再投影する。
- **冪等**: 何度実行しても同じセクションを置換するだけで、副作用が積み重ならない。
  マーカーが決定的なので重複挿入されない。
- **人手セクションを壊さない**: マーカー外は読み取り専用として扱い、一切変更しない。
- **文体**: guide-capture・obsidian-memory に準拠(一文一改行・要点は太字・冗長禁止)。
  AGENTS.md はプレーンテキストなので vault 記法(callout 以外)は使わない。
  callout(`> [!note]`)は README/AGENTS.md でも GitHub が表示するので使ってよい。
