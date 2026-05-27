---
name: codex-consult
description: >-
  行き詰まり時に別モデル(OpenAI Codex)へセカンドオピニオンを求める相談 skill。
  問題状況の要約 + 試したこと + 関連コードをプロンプトに編んで Codex CLI に渡し、
  別の視点を得る。self-review(レビュア)とは隔離方針が真逆で、ここでは**文脈を盛る**。
  「Codex に相談」「セカンドオピニオン」「別モデルの意見」、同一問題で複数回試して
  解決しない時、`/codex-consult` での起動で発火する。個人PC専用(codex 未導入なら skip)。
user-invocable: true
allowed-tools: Bash, Read, Grep, Glob
---

# codex-consult

行き詰まった問題を、別モデル(OpenAI Codex)に相談してセカンドオピニオンを得る。

## self-review との違い(必読)

self-review(レビュア)は**コンテキスト隔離**が品質の核 = 差分のみ渡す。
この skill は**逆**。相談の質は文脈の濃さで決まるので、問題状況・試行錯誤・
関連コードを**積極的に盛って**渡す。別モデルに「自分が見落としている前提」を
突かせるのが狙いなので、隔離はしない。

## 手順

### 1. codex の導入確認(ガード)

```bash
if ! command -v codex >/dev/null 2>&1; then
  echo "Codex 未導入のため相談不可(個人PC専用: mise run setup:codex)"
fi
```

未導入なら上記を明示して**ここで終了**する(壊さない)。業務PC等 codex 不在環境では
この skill は使えない。

### 2. 相談プロンプトを編む

以下を 1 つの stdin プロンプトにまとめる(文脈を盛る = self-review と真逆):

- **問題状況の要約**: 何をしようとして、何が起きているか。期待と実際の差。
- **試したこと**: これまでに試した仮説とその結果(同じ轍を踏ませない)。
- **関連コード / エラー**: 該当ファイルの抜粋・スタックトレース・設定。Read / Grep /
  Glob で集める。長すぎる場合は問題に効く範囲に絞る。
- **聞きたいこと**: 原因の見立て / 別アプローチ / 見落としている前提、など具体的に。

### 3. Codex に渡す

手順 2 で編んだ長文プロンプトを一時ファイルに書き、stdin にリダイレクトして渡す:

```bash
prompt_file="$(mktemp)"
# 手順 2 で編んだ相談プロンプトを $prompt_file に書く
codex exec --sandbox read-only - < "$prompt_file" 2>/dev/null
rm -f "$prompt_file"
```

- 一時ファイル経由にするのは、文脈を盛った長文を heredoc で直書きすると markdown
  リスト内のインデントで終端 `EOF` が壊れる罠を避けるため(self-review は短い指示を
  引数で渡すが、こちらは長文なので stdin が要る)。
- `--sandbox read-only` で書込はさせない(相談のみ。コードは Claude 側で書く)。
- 応答が空 / エラーなら、認証(`codex login`)・ネットワークを疑い、その旨を人間に伝える。

### 4. 応答を統合して人間に提示

- Codex の見立てを**鵜呑みにしない**。別モデルの一意見として扱い、自分の理解と
  照合する(矛盾点・新しい視点を明示)。
- 採否は人間判断に委ねる。有用な打開策が出たら次のアクションを提案する。

## 将来

`codex mcp-server` を MCP として登録すれば、単発の stdin 相談から**往復対話**に
発展できる(Codex に追加質問を返し、文脈を保ったまま深掘りする)。現状は単発の
`codex exec` で十分なため未導入。必要が出たら MCP 化を検討する。

## 原則

- Codex は **CLI 専用に固定**(skill/Agent を経由しない。bare 名衝突を避けるため)。
  前提は個人PC専用のオプトイン導入(`mise run setup:codex`)+ `codex login`(ChatGPT サブスク)。
- read-only 固定。相談で得た案の実装は Claude 側で行う(Codex に書かせない)。
