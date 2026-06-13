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

## hooks / lib / 参謀ゲートの全体像

参謀ゲート(push ゲート・設計レビューゲート・消失検知 Tier 1〜3)は 3 層で実装している:

- `home/dot_claude/hooks/` … ゲートの強制(ブロック・フラグ読取/無効化)
- `home/dot_claude/hooks/lib/` … 共有判定の単一情報源
- `home/dot_claude/skills/self-review/`・`skills/design-review/` … レビュー実施と
  解除フラグの作成(消失検知の実体は `skills/self-review/scripts/` の 3 スクリプト)

- **発火点の正典は `settings.json.tmpl` の hooks セクション**、各 hook の役割の正典は
  そのファイル冒頭ヘッダ。ここに hook の手書き一覧は置かない(陳腐化するため)。
  分類だけ示す: `block-*`(PreToolUse の遮断系)/ `inject-* · rearm-*`(規約注入)/
  `ciwatch-*`(CI 監視の起動・ナッジ)/ `pre-push-* · postcommit-*`(push ゲートの
  フラグ読取・無効化)/ `capture-* · load-* · create-* · pipe-* · pre-edit-* ·
  large-file-*`(個別ヘッダ参照)。
- **lib は共有判定の単一情報源**(キー・判定の完全一致が生命線。インライン複製を
  作らない):

  | lib | 正典として持つもの |
  |---|---|
  | `resolve-git-target.sh` | push/commit/merge の実対象 working dir 導出・コマンド字句解析 |
  | `resolve-repo-key.sh` | 論理 repo キー(対象パス → repo キー。ghq フォールバック込み)の導出 |
  | `resolve-base-ref.sh` | 保護ブランチ一覧(`is_protected_branch`)と最近接保護祖先(`resolve_base_ref`) |
  | `flag-paths.sh` | `/tmp/claude-sessions` の全ゲートフラグのキー導出 |
  | `test-patterns.sh` | テストファイル判定・テスト観点カウントの ERE |
  | `design-gate.sh` | 設計レビューゲート(Gate 1/2)の除外判定・フラグ評価・昇格 |

- **ゲートに止められた時の解除手順**: push ゲート = `/self-review`(skill 参照)、
  設計レビューゲート = `/design-review` または人間承認の理由付き trivial-override
  (Gate 2 のブロックメッセージが具体手順を案内)。運用の詳細は外部脳の
  `Guides/_topics/参謀ゲート運用.md`。
- **hook を開発・変更する時**: 作法と既知の罠は外部脳の
  `Guides/cc-dotfiles/claude-hook開発.md`。挙動を変えるリファクタは scratch repo の
  ケース表テスト(旧/新 hook の同一入力突き合わせ)を PR 本文に記録する。
