---
name: self-review
description: >-
  push 前の汎用品質レビュー隊。push 対象 diff を /code-review・security-review・
  CodeRabbit の3者で検査し、severity 順に人間へ提示してトリアージを促す。
  「セルフレビューして」「push 前に確認」、`/self-review [effort]` での起動、
  またはオーケストレータが push 直前に実行する。レビュー実施 + 人間トリアージ
  済を確認した時だけ push ゲートのフラグを立てる。指摘ゼロは強制しない。
user-invocable: true
allowed-tools: Bash, Read, Grep, Glob
---

# self-review

push 前の汎用レビュー隊。3者(code-review / security-review / CodeRabbit)の
指摘を統合し、人間がトリアージできる状態にして push を解禁する。

## 手順

1. **対象 diff の特定**: `git branch --show-current` で現在ブランチを確認。
   push 対象は「未 push コミット + 作業ツリー変更」。base ref は ①upstream
   追跡があれば `@{u}` ②無ければデフォルトブランチ(`main`/`master`)で決め、
   `git diff <base>...HEAD`(三点記法)+ `git diff` で全体を把握。
   保護ブランチ(`main`/`master`/`develop`/`epic/*`)上では gate 自体が無効
   (`pre-push-selfreview-gate.sh` が除外)なので、このスキルの対象外。
2. **code-review**: `/code-review` を effort=medium で実行。`/self-review`
   に effort 引数が渡された場合はそれで上書きする。
3. **security-review**: `security-review` を実行。
4. **CodeRabbit**: `command -v coderabbit` で導入を確認。
   - あれば `coderabbit --agent` で push 対象を base=デフォルトブランチと比較
     して実行(JSON 出力。push 対象を見る `--type`/`--base` を選ぶ)し、
     severity 別に集計する。
   - 未導入・未認証・ネットワーク不可なら `CodeRabbit: skip(未導入/未認証)`
     と明示して続行する(ブロックしない)。
5. **統合提示**: 3者の指摘を統合し、severity 順に人間へ提示する。
6. **判定とフラグ**:
   - 通過条件は「レビュー実施 + 人間がトリアージ済(修正 or 意図的見送り)」。
     **指摘ゼロは強制しない。**
   - トリアージ完了を確認したらフラグを立てる:
     ```sh
     branch="$(git branch --show-current)"
     safe="$(echo "$branch" | tr '/' '-')"
     mkdir -p /tmp/claude-sessions
     touch "/tmp/claude-sessions/review-passed-${safe}"
     ```
     これで `pre-push-selfreview-gate.sh` が解除される。
   - レビュー未実施・トリアージ未了ならフラグを書かない。

## 原則

- フラグは「現在の HEAD をレビュー済」の意味。`git commit` 後は
  `postcommit-invalidate-review.sh` がフラグを無効化するので、新規コミット後は
  再レビュー必須。
- 保護ブランチ(`main`/`master`/`develop`/`epic/*`)では gate が無効。push/merge
  の可否判断は `block-protected-branch-push.sh` と人間判断に委ねる。
- CodeRabbit の手動入口として公式プラグインのコマンド `/coderabbit:review`
  も使える(いずれも CodeRabbit CLI 本体と `coderabbit auth login` が前提)。
