# dotfiles-lsp

cc-dotfiles が管理するローカル LSP プラグイン。Claude Code のビルトイン LSP tool に
言語サーバーを供給する。

## 提供する言語サーバー

| 言語 | command | バイナリの出所 |
|---|---|---|
| TypeScript / JavaScript | `vtsls` | dotfiles: `npm:@vtsls/language-server` |
| Lua | `lua-language-server` | dotfiles: `lua-language-server` |
| Markdown | `marksman` | dotfiles: `marksman` |
| JSON | `vscode-json-language-server` | dotfiles: `npm:vscode-langservers-extracted` |
| CSS | `vscode-css-language-server` | 同上 |
| HTML | `vscode-html-language-server` | 同上 |

## 設計

- サーバー定義は `.claude-plugin/marketplace.json`(chezmoi template)に inline。
- `command` は **mise shims の絶対パス** (`~/.local/share/mise/shims/<bin>`) を指す。
  mise はシェルフック (`mise activate`) で PATH を通すため、Claude Code が
  非対話で LSP を spawn する際は素の PATH に乗らない。shim 絶対パスなら
  空 PATH でも解決するため確実(`env -i` でも動作確認済み)。
- バイナリ実体は **dotfiles リポの mise** (`~/.config/mise/config.toml`) が管理。
  Neovim (`~/.config/nvim/lua/plugins/lsp.lua`) と同じ実体を共有する。
- TS は性能重視で `typescript-language-server` ではなく `vtsls` を採用
  (職場の大規模 legacy コードベース対応)。
- ESLint LSP は vtsls と拡張子の所有が競合し設定も煩雑なため意図的に未収録。
  必要時に `vscode-eslint-language-server` を追記する。

## 有効化

`~/.claude/settings.json` の `extraKnownMarketplaces` で登録し
`enabledPlugins` で有効化する(cc-dotfiles の `settings.json.tmpl` が管理)。
