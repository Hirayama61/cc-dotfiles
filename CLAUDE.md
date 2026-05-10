# CLAUDE.md

このリポジトリは Claude Code の設定(`~/.claude/` 配下)を管理する dotfiles です。

## 関連リポ

- [`Hirayama61/dotfiles`](https://github.com/Hirayama61/dotfiles) — 端末/開発環境の設定全般。chezmoi + mise のオーケストレータが置かれている。**適用はそちらの mise から実行する。**
- このリポは `~/.claude/` 専用の chezmoi ソース置き場。

## 構成

dotfiles リポと同じ chezmoi 構成:

- `.chezmoiroot` → `home`
- `home/dot_claude/...` → `~/.claude/...` に展開

## 適用

```sh
cd ~/ghq/github.com/Hirayama61/dotfiles
mise run apply:cc-dotfiles
```

`mise run apply`(両リポ一括)でも適用される。削除自動化(`bin/sync.sh` の snapshot diff)も dotfiles 側の機構が cc-dotfiles 用にも働く。

## 管理する/しないファイル

| パス | 管理 | 理由 |
|---|---|---|
| `~/.claude/settings.json` | ✓ | ユーザ設定 |
| `~/.claude/CLAUDE.md` | ✓ | グローバル指示書(将来追加時) |
| `~/.claude/agents/` | ✓ | カスタムエージェント |
| `~/.claude/skills/` | ✓ | カスタムスキル |
| `~/.claude/commands/` | ✓ | カスタムスラッシュコマンド |
| `~/.claude/hooks/` 系設定 | ✓ | settings.json 内の hooks セクション含む |
| `~/.claude/sessions/`, `projects/`, `cache/`, `downloads/`, `file-history/`, `history.jsonl`, `backups/`, `shell-snapshots/`, `telemetry/`, `session-env/`, `tasks/`, `plans/`, `mcp-needs-auth-cache.json` | ✗ | ランタイム/キャッシュ |
| `~/.claude/plugins/` | ✗ | プラグインインストーラが自動管理 |

## 規約

- **dot_ プレフィックス**: `home/dot_claude/settings.json` → `~/.claude/settings.json` に展開される。
- **適用は dotfiles 経由で**: このリポ単独で `chezmoi apply` を直接呼ばない。snapshot 削除自動化を経由しないと孤児が残る。
- **ランタイム系ファイルを誤って source に置かない**: 上の表を確認してから追加する。
