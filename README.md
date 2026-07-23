# cc-dotfiles

Claude Code (`~/.claude/`) の dotfiles。chezmoi で管理。

オーケストレータと適用方法は [Hirayama61/dotfiles](https://github.com/Hirayama61/dotfiles) を参照。

## 適用

```sh
cd ~/ghq/github.com/Hirayama61/dotfiles
mise run apply:cc-dotfiles
```

詳細は [CLAUDE.md](./CLAUDE.md) を参照。

## コンテキスト逼迫ゲートの脱出口(人間専用)

コンテキスト使用率 50% 超で編集がブロックされたとき、緊急で続行が必要なら
プロンプトに `context-gate-override` と書くと **1 回だけ**ゲートが解除される。
このフレーズは人間専用の脱出口であり、Claude に打たせない(hook の deny 理由にも
出さない)。通常の解除経路は `/compact-prep` → `/compact`。
