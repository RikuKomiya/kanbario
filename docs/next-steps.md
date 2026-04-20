# Next Steps (2026-04-20 時点)

MVP 完成までの次アクション備忘録。spec.md §8 のマイルストーン計画を
実装しながら更新した版。**次のセッションはここから読む**こと。

---

## 現状サマリ

- 現 branch: `main` (PR #2 = merge commit `71137ee` で `feat/milestone-c-hook-integration` を取り込み済み)
- **Milestone A / B / C / D すべて完了** (MVP 主要マイルストーン全終了)
- 実機で end-to-end 動作確認済み (claude が hook を吐いて Kanban カラムが inProgress ↔ review 遷移する)
- **次の着手先は UI 反映と仕上げ** — 本ファイル §「残タスク」の優先順序参照

### 動く end-to-end フロー

1. toolbar の Choose Repo で git リポジトリを選択
2. New Task (⌘N) でタスク追加 (planning 列)
3. 詳細画面で Start → wt が worktree を作成、libghostty が claude (shim 経由) spawn、planning → inProgress
4. **色つきターミナル**で claude と直接対話 (キーボード入力 / 日本語入力 / マウス selection / スクロール)
5. claude のターン終了 (Stop hook) → Kanban カードが **inProgress → review に自動移動**
6. ユーザーが詳細画面でメッセージ送信 (UserPromptSubmit hook) → **review → inProgress に戻る**
7. Stop ボタンで `ghostty_surface_request_close` (SIGHUP) → プロセス exit (SessionEnd hook) → review
8. review → done drag で wt remove + teardown

---

## Kanban カラムの意味論 (重要)

- `planning` = まだ start していない
- `inProgress` = claude が能動的に作業中 (tool 実行 / reasoning)
- `review` = claude のターン終了 = ユーザー入力待ち (cmux の "needsInput" に相当) もしくは claude プロセス exit 後の停止
- `done` = ユーザーが完了とした (手動 drag、cleanup 発火)

claude が動くたびにカードが `inProgress ↔ review` を行き来する。ボード見るだけで「自分待ちか claude 作業中か」が分かる UX。

`Stop hook → review` / `UserPromptSubmit hook → inProgress` が要点。「review = プロセス死亡」と勘違いしないこと (実装段階で一度ミスして fix した経緯あり、PR #2 の `871d420` 参照)。

---

## 残タスク (優先順)

### 🟡 UX 反映 (MVP の体感価値を上げる)

- [ ] **バッジ View** — `TaskDetailView` / `KanbanBoardView` のカードに `appState.activitiesByTaskID[task.id]` を読む badge を出す (~15 行)
  - `inProgress` カラム内で「今 reasoning か tool 実行か」の細粒度表示の足場にもなる
- [ ] **macOS 通知** — UNUserNotificationCenter + Info.plist の `NSUserNotificationAlertStyle`、`AppState.handleHook` の `case "notification"` を埋める (~30 行)

### 🟢 ドキュメント整備

- [x] **ADR 0002**: Milestone 順序反転 (D → C) の意思決定記録 (`docs/adr/0002-milestone-order-d-then-c.md`、本 PR で追加)
- [x] **ADR 0003**: cmux 機能再現 (B 路線) を選んだ意思決定記録 (`docs/adr/0003-cmux-feature-parity-not-line-by-line.md`、本 PR で追加)

### ⚪ 後回し (MVP では不要、必要になった時点で)

- **GRDB 導入**: event log が必要になった時点で
- **Settings UI**: asdf / mise ユーザー向けに extra PATH / claude path を設定できるようにする
- **自前 GhosttyKit.xcframework release**: zig build が遅すぎて辛くなったら、自 fork を立てて prebuilt tar.gz を GitHub Release に置き、`download-prebuilt-ghosttykit.sh` を追加する (cmux の二段構え方式)
- **Run Script で `./scripts/ensure-ghosttykit.sh` 自動実行**: 現状は手動実行前提
- **action_cb の `cellSize` を `GHOSTTY_ACTION_CELL_SIZE` 通知から埋める**: 0 固定で IME 候補 window 初期位置がズレる可能性
- **Focus 復旧経路の整備**: cmux の `requestPointerFocusRecovery` 相当は未移植 (split / tab 無しの kanbario MVP では問題になりにくい)
- **マウスホバー / command-click で open-in-editor**: cmux の `ghostty_surface_quicklook_word` 経路は未移植

---

## 完了したマイルストーン (アーカイブ)

### Milestone A: 状態モデル + Kanban UI ✅
基本のタスクモデル / 4 カラム drag&drop / 永続化。詳細は git log と ADR 0001 参照。

### Milestone B: WorktreeService ✅
`worktrunk` (`wt` CLI) を subprocess で叩く wrapper。create / remove / branch.

### Milestone C 前半: Start → claude spawn ✅
planning カードの Start ボタンで wt + claude 起動、プロセス exit で review に同期遷移。

### Milestone D: libghostty 描画 ✅ (cmux 完全踏襲)

cmux `Sources/GhosttyTerminalView.swift` の約 20 % を kanbario 側に写経。

完了内容:
- `GhosttyKit.xcframework` 取得基盤 (`scripts/ensure-ghosttykit.sh` + `scripts/ensure-zig.sh`)
- Xcode 統合 (`OTHER_LDFLAGS = -lc++`、xcframework symlink、Embed OFF)
- `GhosttyApp.swift` (singleton + runtime callback)
- `GhosttyTerminalView.swift` (TerminalSurface + GhosttyNSView + CAMetalLayer)
- キー入力 / IME (NSTextInputClient) / マウス / スクロール
- `ClaudeSessionFactory` (264 → 100 行に縮退、PTY 所有を libghostty に移譲)

実機で日本語入力 / マウス selection / scroll momentum まで動作確認済み (2026-04-19)。

### Milestone C 後半: hook 統合 ✅ (PR #2、cmux 機能再現)

cmux 14k 行から 300 行に圧縮 (機能再現方針、ADR 0003)。

完了内容:
- `KanbarioCLI` Xcode target (Command Line Tool、PRODUCT_NAME = `kanbario`)
- `CLI/main.swift` — Unix socket への 1 行 JSON relay (108 行)
- `Kanbario/HookReceiver.swift` — POSIX socket listener + 背景 thread accept (173 行)
- `AppState.handleHook(_:)` — 6 event を Kanban カラム遷移にマッピング
- `Resources/bin/claude` — bash shim (--settings JSON で hook 注入)
- `Copy Hook Bin` build phase で App bundle に shim と CLI を埋め込み

実機で hook 発火 → Kanban カラム遷移を確認 (2026-04-20)。

---

## 参照

- [docs/spec.md](spec.md) — 仕様全文
- [docs/adr/0001-kanban-drag-drop-swiftui-only.md](adr/0001-kanban-drag-drop-swiftui-only.md)
- [docs/adr/0002-milestone-order-d-then-c.md](adr/0002-milestone-order-d-then-c.md)
- [docs/adr/0003-cmux-feature-parity-not-line-by-line.md](adr/0003-cmux-feature-parity-not-line-by-line.md)
- **cmux** (最重要、参照実装): https://github.com/manaflow-ai/cmux
  - `scripts/ensure-ghosttykit.sh` — libghostty cache + ranlib refresh
  - `Sources/GhosttyTerminalView.swift` — NSView + Metal layer の実装
  - `Resources/bin/claude` — shim スクリプト
  - `CLI/cmux.swift` — hook CLI の実装
- Sessylph: https://zenn.dev/saqoosha/articles/sessylph-libghostty-claude-code-terminal
- Ghostling: https://github.com/ghostty-org/ghostling (libghostty 最小 init)
