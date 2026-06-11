---
name: design-review
description: >-
  実装前の Plan(設計)の独立レビュー隊。design-reviewer Agent + Codex CLI(あれば)へ
  Plan + 要件 + 関連既存コード + 用語集を渡して並列検査し、人間トリアージ通過で
  design-reviewed フラグを立てて設計レビューゲート(Gate 1/2)を解除する。
  「設計レビューして」「プランをレビュー」、`/design-review` での起動、または
  ExitPlanMode / 編集が設計レビューゲートにブロックされた時に実行する。
user-invocable: true
allowed-tools: Bash, Read, Grep, Glob, Agent, AskUserQuestion
---

# design-review — 実装前の設計レビュー隊

self-review(push 前・差分ベース)の**設計時版**。Plan が実装に入ってよい品質かを、
文脈リッチな独立レビュアで検査する。通過条件は「レビュー実施 + 人間がトリアージ済」。

## コンテキスト隔離の原則(self-review と非対称な点に注意)

- reviewer には **Plan・要件・関連既存コード/パターン・用語集**を渡す
  (= 文脈リッチ。差分しか渡さない self-review と違い、設計の妥当性判断には
  要件と既存コードの文脈が必要)。
- **渡さないもの: 会話中の正当化・経緯・「この設計で良いと思う理由」**。
  レビュアに自分の思い込みを引き継がせない(エントロピー抵抗の欠如の排除)。

## 手順

### 1. レビュー材料の確定

- **Plan 本文**: これから確定しようとしている Plan(ExitPlanMode に渡す内容
  そのもの、または直近で提示した実装計画)。
- **要件**: ユーザー依頼の原文(要約しない。要約は思い込みの混入点)。
- **関連既存コード**: Plan が触る・依拠する主要ファイルのパス一覧
  (reviewer は Read/Grep で自分で読む。本文を貼る必要はない)。
- **用語集**: `~/obsidian/brain/Tasks/<repo>/CONTEXT.md` があればそのパス
  (repo は `resolve-repo-key.sh "$PWD"` で導出)。
- 材料は一時ファイル(`/tmp/claude-sessions/design-review-input-*` 等)に
  まとめて reviewer へパスで渡す。

### 2. reviewer を 1 レスポンスで並列起動

- `Agent(subagent_type: "design-reviewer")` — 6 観点の反証レビュー
  (観点定義は agent 側が単一情報源。モデルは inherit = メインと同格)。
- Codex CLI(あれば。無ければ skip を明示して続行 — ブロックしない。
  stdin + PROMPT 引数の併用は self-review と同じ作法 — `codex exec` は stdin を
  `<stdin>` ブロックとして指示に追記する):
  ```bash
  # input_file = 手順 1 で作ったレビュー材料ファイルのパス
  if command -v codex >/dev/null 2>&1; then
    codex_out="$(cat "$input_file" \
      | codex exec --sandbox read-only \
          "次の実装 Plan を設計レビューせよ。要件網羅/既存パターン整合/用語整合/スコープ妥当性/テスト方針/未検証前提の6観点で、重大/改善/情報の3段階の指摘と理由を出力せよ。")"
    [ -n "$codex_out" ] && printf '%s\n' "$codex_out" || echo "Codex: skip(空応答)"
  else
    echo "Codex: skip(未導入)"
  fi
  ```

### 3. 統合と提示

self-review と同じ統合規約(severity 正規化・重複統合・`F-NNN` 採番・
判断 `語:理由` を右端)で提示する。design-reviewer の `VERDICT` 行は総評に転記する。

### 4. 人間トリアージとフラグ

- 通過条件 = 「レビュー実施 + 人間がトリアージ済(must-fix の反映 or 意図的見送り)」。
- must-fix を Plan に反映した場合、変更が設計の方向を変えるなら再レビュー、
  字句修正なら人間の判断で省略してよい。
- トリアージ完了を確認したらフラグを立てる(キーは `flag-paths.sh` が単一情報源。
  **レビュー対象 repo 内(`$PWD`)で実行する**):
  ```sh
  repo="$("$HOME/.claude/hooks/lib/resolve-repo-key.sh" "$PWD" 2>/dev/null || true)"
  [ -n "$repo" ] || { echo "repo key が引けない。中断" >&2; exit 1; }
  mkdir -p "$("$HOME/.claude/hooks/lib/flag-paths.sh" dir)"
  # セッション昇格用 pending(次の Gate 評価が自セッションへ取り込む)
  printf 'reviewed: %s\n' "$(date '+%Y-%m-%d %H:%M')" \
    > "$("$HOME/.claude/hooks/lib/flag-paths.sh" design-reviewed-pending "$repo")"
  # 現在ブランチが feature ブランチなら branch フラグも立てる(セッション跨ぎの続き用)
  branch="$(git branch --show-current 2>/dev/null || true)"
  case "$branch" in
  "" | main | master | develop | epic/*) : ;;
  *) touch "$("$HOME/.claude/hooks/lib/flag-paths.sh" design-reviewed "$repo" "$branch")" ;;
  esac
  ```
- **スコープ宣言の記録(Tier 3 用)**: Plan が触ると宣言した path/glob を
  1 行 1 件で書く(self-review のスコープ乖離チェックが照合する。glob は
  bash の case パターン形式。ディレクトリは `dir/*` と書く):
  ```sh
  scope_file="$("$HOME/.claude/hooks/lib/flag-paths.sh" design-scope-pending "$repo")"
  case "$branch" in
  "" | main | master | develop | epic/*) : ;;
  *) scope_file="$("$HOME/.claude/hooks/lib/flag-paths.sh" design-scope "$repo" "$branch")" ;;
  esac
  printf '%s\n' 'path/to/file.sh' 'dir/subdir/*' > "$scope_file"
  ```
  (`path/to/file.sh` 等はプレースホルダー。実際の Plan が宣言した path/glob に
  必ず置き換える)
- レビュー未実施・トリアージ未了ならフラグを書かない。

## 原則

- **Gate 1(ExitPlanMode)は trivial-override では通れない**: Plan を立てた時点で
  「軽微」ではない。軽微タスクの脱出口(trivial-override)は Gate 2 専用で、
  人間の明示承認 + 理由必須(Gate 2 のブロックメッセージが作法を案内する)。
- フラグは branch スコープ(commit では無効化しない)+ セッションスコープの併用。
  worktree を跨ぐ delegate 分業はセッションフラグがカバーする。
- branch フラグは repo+branch キーで /tmp に残る(worktree の破棄では消えない)。
  同名ブランチを切り直すと旧フラグで Gate が素通りしうるが、自分の Claude を縛る
  best-effort として受容する(気になる時は手で消す。再起動でも消える)。
