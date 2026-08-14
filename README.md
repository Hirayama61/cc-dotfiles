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
プロンプトに `context-gate-override` を**単独の行として**書くと **1 回だけ**ゲートが
解除される(会話中の言及では発動しない。行全体がこのフレーズのみであること)。
このフレーズは人間専用の脱出口であり、Claude に打たせない(hook の deny 理由にも
出さない)。通常の解除経路は `/compact-prep` → `/compact`。

## state file の自動更新

使用率 30% 以降、Claude は作業の切れ目(ターン終了時)に compact-prep を自分で実行して
state file を更新する。人間は `/compact` を打つだけでよく、更新を指示する必要はない。

自動更新が走らなかった場合(usage.json が無い・古い、構造検証に通らない等)は、
`/compact` を打った時点で PreCompact ゲートが 1 回止めて compact-prep を要求する。

state file が「古い」かどうかは**経過時間では決まらない**。state を確定した時点からの
ターン差(3 未満)と使用率の増分(10 ポイント未満)で測るので、放置しても古くならず、
逆に 1 ターンで大量に消費すれば古くなる。
ただし state を確定した時点の使用率が読めなかった場合(圧縮直後など)は使用率の次元が
落ち、ターン差だけで判定する。

自動更新には打ち止めがある。state が新鮮にならないまま 3 ユーザーターン続くと
ナッジは黙るので、その間は自動更新が走らない(次に state が新鮮になると復帰する)。
黙っている間に `/compact` を打てば PreCompact ゲートが止めて気づける。
ただしこのブロックは 1 ctx につき 1 回だけで、一度止まってから圧縮せずに作業を続けた
場合、次の `/compact` は state が古くても通る(恒久ブロックを避けるための仕様)。
