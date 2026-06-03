# ~/.claude/CLAUDE.md — グローバル作業規約

全プロジェクト共通の最小規約。hook で守れる事項はここに書かない(hook が必要な
瞬間にメッセージで強制する)。ここに残すのは hook 化できない「挙動の核」のみ。

## オーケストレーション(相談と実行の分離)

非自明な作業は「メイン = 相談 / 判断 / 委譲」「delegate = 単一作業」に
コンテキスト分離する。浅い調査の伝播・無計画実行による品質低下を防ぐ。

- **メインの役割**: 対話・判断確認・タスク分解・委譲・プランレビュー・統合のみ。
  非自明な実装/調査を本体コンテキストで直接やらない。
- **委譲**: `Agent`(subagent_type: `delegate`)に1タスクずつ。独立作業は
  `run_in_background`、変更を伴う作業は `isolation: "worktree"`。
  依存関係に沿って直列/並列を選ぶ(密結合な逐次作業を並列化しない)。
- **タスク追跡**: ネイティブ Task ツールを使う(Agent teams の共有リストで
  lead が横断把握)。自前ファイルを作らない。
- **プランレビューゲート**: 非自明タスクは delegate にプランのみ先出しさせ、
  返ってきた plan をメインが**軽量に**レビュー(再立案はしない)。判断・曖昧点・
  業務決定は**作業前に**人間へエスカレーションし、解決後に実行を指示。
- **深さはファイル、チャットは要約のみ(品質の根因)**: delegate は詳細を
  成果物ファイルに書き要約だけ返す(具体手順は delegate 定義が所有)。メインも
  それを前提にファイルを読み、深い内容を自分の context に持ち込まない。
- **計画**: 複数ステップ依頼はメインが Plan モードを通してから委譲。
- **完了通知**: background 完了イベントで人間との判断やりとりを中断しない。
  安全な切れ目でまとめて reconcile する。
- **委譲前の外部脳検索(種渡し)**: 委譲前にメインが `~/obsidian/brain` を
  Grep/Glob で keyword 検索し、ヒットした関連ノートを delegate プロンプトに
  「既知の前提(参考ノート)」として種渡しする。重複調査を構造的に潰す。
- **外部脳への reconcile**: delegate から `外部脳候補` / 鮮度 flag を受けたら、
  安全な切れ目で reconcile する(値する候補を obsidian-memory で書き戻し / 陳腐化
  ノートは非破壊で訂正 = callout 追記 or 人間へ申告)。書き戻し完了まで reconcile を
  閉じない。
- **判断の記録(AskUserQuestion → Decisions)**: 重要な二者択一はメインが
  AskUserQuestion を積極利用する。確定後、PostToolUse hook(`capture-decision.sh`)が
  リマインドを注入するので、安全な切れ目で **obsidian-memory を使い理由・文脈付きの
  Decisions ノートを書く**。timing とファイル分割はメイン判断(セッション単位の
  寄せ集めも質問単位のファイル乱造も避ける)。
- **doc-gravity(生成ドキュメントは外部脳へ)**: Claude が生成する作業ドキュメント
  (plan/report/findings 等)は全て `~/obsidian/brain/Tasks/<repo>/` に書く(`<repo>` は
  `resolve-repo-key.sh` で導出)。リポ作業ツリー配下の**新規 .md は PreToolUse(Write) hook が
  ブロック**する(dev doc 許可リスト=README/CONTRIBUTING/CHANGELOG/LICENSE/CLAUDE/AGENTS/
  SECURITY・docs/**・.github/**、既存 .md 編集、`.claude/**`・chezmoi ソース `home/dot_*` は
  除外)。これは hook の強制そのものではなく**書込先の方針**(hook は最後の砦)なので明記する。
- **grill-with-docs の Obsidian 振替(doc-gravity の個別適用)**: ext-skill
  `grill-with-docs` は本来 CONTEXT.md(用語集)を repo 直下に、ADR を `docs/adr/` に
  生成するが、本環境では出力先を Obsidian に振り替える(スキル本体は upstream symlink
  ゆえ不可侵。この指示が skill の default を OVERRIDE する)。
  - **用語集** = `~/obsidian/brain/Tasks/<repo>/CONTEXT.md`(`<repo>` は
    `resolve-repo-key.sh` 導出。空を返す非 git 文脈では `Tasks/_misc/CONTEXT.md` に退避)に
    read/write。repo 配下に CONTEXT.md/CONTEXT-MAP.md を作らない(hook が新規 .md を
    ブロックするので本来そもそも生成されない)。
  - **探索の短絡**: セッション開始時に repo を CONTEXT.md/CONTEXT-MAP.md/`docs/adr` で
    走査しない。`~/obsidian/brain/Tasks/<repo>/CONTEXT.md` の1パスだけ確認し、
    無ければ最初の用語確定時に lazy 作成する(毎回の空振り探索を構造的に潰す)。
  - **ADR**: in-repo `docs/adr/` を新設せず、ADR 相当(Hard to reverse ∧ Surprising ∧
    実トレードオフ)は上の「判断の記録」と同じ Decisions ノート(obsidian-memory)へ合流させる
    (`docs/adr/**` は doc-gravity hook の `docs/**` 許可を素通りするので、これは hook 強制で
    なく規約遵守で担保する点に注意)。
  - 個人リポは単一コンテキスト前提。複数コンテキストが要れば1ノート内を見出しで分割する。

## worktree 並行作業(1 worktree = 1 ブランチ)

複数の Claude を並行させる際の挙動の核。判断軸は「案件」ではなく**ブランチ**。
gwq 導入手順やディレクトリ構成の詳細はプロジェクト側に置き、ここでは守らせる
判断だけ書く。人間も Claude も**同一規約**に従う。

- **既定 = モデルB(ディスパッチャ型)**: main Claude が worktree を用意し、実作業は
  `delegate`(`isolation:"worktree"`)/ `gwq exec` / `git -C <path>` に振る。
  main は自分の作業ツリーを汚さず指揮に徹する。人間が手で worktree を作って各々に
  Claude を常駐させる運用も同じ規約の下で残す。
- **worktree 作成は必ず `bin/wt.sh <branch> [base]` 経由**: 正規パスは
  `~/ghq/github.com/Hirayama61/dotfiles/bin/wt.sh`(どのリポからでもこの絶対パスで
  呼べる)。worktree の絶対パスを stdout に返すので `cd "$(~/ghq/.../bin/wt.sh feature/x)"`
  の形で使う。フラット配置・正しい checkout・ネスト/二重 checkout 拒否はスクリプトが
  保証する。**素手の `git worktree add` / `gwq add` / `claude --worktree` はしない
  (hook でブロックされる)**。
- **1 worktree = 1 ブランチ**: 同じブランチの続きは既存 worktree を使い、別
  ブランチを切るなら新しい worktree を作る。同一ブランチを2つの worktree で
  同時に開かない(新規作業を始める前にこの分岐をまず判断する)。`wt.sh` は冪等なので
  既存ブランチには既存 worktree のパスを返す。
- **フラット配置・ネスト禁止**: worktree は `~/worktrees/host/owner/repo/branch`
  にフラットに並ぶ(メイン clone は `~/ghq/...` に温存)。**案件 worktree の中で
  `claude --worktree` を実行してネストさせない**。worktree 内では素の `claude` を使う。
- **案件 = Epic 配下の複数タスク**: 1案件で複数ブランチが要るなら、同じ clone から
  epic ブランチを派生させ、その下にタスクごとの worktree を `wt.sh` で並べる。
- **並列は2〜3が現実的上限**: 増やしすぎない。「今どの案件がどこで動いているか」の
  真実の源は `gwq status` / `gwq list`(手で cd して探さない)。
- **ローカル vs クラウドの住み分け**: 今この手で進める実装/レビューはローカル
  (Claude Code CLI + gwq)、投げて待てる独立作業はクラウド(Cowork)。**同じ案件を
  ローカルとクラウドで同時に触らない**。

## 調査と実装の規律

- **未検証を事実と断言しない**: 確信のない点はヘッジするか flag する(常時 ON。
  コストはほぼゼロ)。これと「裏取りに動く」は別物として扱う。
- **裏取りはコストで gate する**: 一次情報(コード / git ログ / 公式ドキュメント)を
  取りに行くのは「間違えると不可逆 or 影響大」**かつ**「裏取りで次の一手が変わる」を
  両方満たす時だけ。どちらかが no なら、最も妥当な解釈で進め、置いた前提を1行添える
  (ユーザーが安く訂正できる)。トピック種別(コーディング/雑務)で判断しない。
- **決定の蒸し返しをしない**: ユーザーが既に下した判断・好みは裏取りで正当化しない。
  検証してよいのは「実行の正しさに効く運用制約」だけ(例: 命名は決定事項だが、
  その命名が踏む OS/FS の制約は検証に値する)。
- **跨ぎ前提は再検証**: セッション/時間を跨ぐ前提(「保留」「未コミット」「未作成」等)は
  古い可能性があるので、依拠する前に都度再検証する。
- **既存パターンに合わせる**: 実装前にリポ内の同種ファイルを複数調べ、最近
  更新されたものを重視しつつ prevailing な実装パターン(命名・構造・規約)を
  把握してから沿って書く。単一の最新ファイルだけを正とせず外れ値に注意。
- **詰まったら別モデルに相談**: 同一問題で N 回(目安 3 回)試しても解決しない時は、
  自分の文脈に閉じず `codex-consult` skill で別モデル(Codex)のセカンドオピニオンを
  取る。自己検知が確実でないため hook ではなく**指示ベース**(自分で気づいて発火する)。
  個人PC専用で codex 未導入なら skip される。
