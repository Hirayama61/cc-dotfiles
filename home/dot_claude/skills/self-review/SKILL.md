---
name: self-review
description: >-
  push 前の構造化セルフレビュー。現在ブランチの diff を、蓄積された業務知識
  (feedback 型メモリ)+ 品質チェックリストに照合する。指摘ゼロで通過した時
  だけ push ゲートのフラグを立てる。「セルフレビューして」「push 前に確認」
  またはオーケストレータが「実装完了」を宣言する直前に起動。指摘が残る場合は
  フラグを書かず、修正 or 人間へのエスカレーションを行う。
user-invocable: true
allowed-tools: Bash, Read, Grep, Glob
---

# self-review

push 前の最後の品質ゲート。**通過した時だけ**フラグを立て、push を解禁する。
目的は「人間の指摘が要らないレベルの成果物」を、人間が確認できる状態で出すこと。

## 手順

1. **対象特定**: `git branch --show-current` と
   `git diff <base>...HEAD`(base は通常 main/develop)で変更全体を把握。
2. **業務知識の照合(最重要)**: `~/.claude/projects/<sanitized-cwd>/memory/` の
   feedback / project 型メモリを読み、過去に人間から受けた指摘・規約・好みに
   この diff が違反していないか1件ずつ突き合わせる。ハーネスが system-reminder で
   recall したメモリも同様に扱う。
3. **品質チェックリスト**:
   - 要件/プランとの整合(やり残し・スコープ逸脱が無いか)
   - 周辺コードの規約・命名・スタイルに合っているか
   - エラー処理・境界・後方互換
   - テスト/型/lint が通る状態か(必要なら実行)
   - secret/認証情報の混入が無いか
   - 不要なデバッグ出力・コメントアウト・暫定コードの残骸
4. **判定**:
   - **指摘ゼロ** → フラグを立てる:
     ```sh
     branch="$(git branch --show-current)"
     safe="$(echo "$branch" | tr '/' '-')"
     mkdir -p /tmp/claude-sessions
     touch "/tmp/claude-sessions/review-passed-${safe}"
     ```
     これで `pre-push-selfreview-gate.sh` が解除される。
   - **指摘あり** → フラグを**書かない**。自分で直せるものは直し、再レビュー。
     業務知識・判断を要するものは修正せず、内容を明確に提示して人間へ
     エスカレーションする(勝手な判断をしない)。

## 原則

- フラグは「現在の HEAD をレビュー済」の意味。`git commit` 後は
  `postcommit-invalidate-review.sh` が自動で無効化する。再 push には再レビュー必須。
- 保護ブランチ(main/develop/epic/**)への push/merge はこのスキルでは解禁できない
  (`block-protected-branch-push.sh` が専任。人間判断のみ)。
- 人間からの新しい指摘・業務知識は、その場で feedback 型メモリに保存する。
  次回以降の self-review が自動でそれを照合し、同じ指摘の再発を漸減させる。
