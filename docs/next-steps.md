# Next Steps (2026-04-19 時点)

MVP 完成までの次アクション備忘録。spec.md §8 のマイルストーン計画を
実装しながら更新した版。**次のセッションはここから読む**こと。

---

## 現状サマリ

- `feat/milestone-c-claude-hook` を main に merge 済み
- Milestone A/B 完了、Milestone C 前半 (Start → wt + claude spawn → exit で review) 完了
- 暫定 sessionPane (ANSI 剥がしログ + Stop + 入力欄) を TaskDetailView に実装済み

### 動く end-to-end フロー

1. toolbar の Choose Repo で git リポジトリを選択
2. New Task (⌘N) でタスク追加 (planning 列)
3. 詳細画面で Start → wt が worktree を作成、claude spawn、inProgress へ
4. 入力欄から Claude に文字列送信、Stop で kill
5. プロセス exit で review に自動遷移、review → done drag で wt remove + cleanup

### 既知の弱点 (これが次の着手の動機)

- **TUI ノイズ**: ANSI stripping の限界で spinner 再描画が積み重なり、claude の返答が読みにくい
- **状態バッジ無し**: needsInput / reasoning 中の表示が無い (hook 未統合のため)
- **リサイズ無効**: PTY は 120x40 固定

---

## 次にやること: Milestone D (libghostty 描画) を先行

spec.md §8 の順序を **C(hook) → D** から **D → C(hook)** に反転する。

**理由**: TUI ノイズが唯一の「使い物にならない」要因で、libghostty が入ると
暫定 sessionPane 自体が不要になる。hook は「状態バッジの精度向上」の polish 扱いに格下げできる。

### 着手チェックリスト

- [ ] `scripts/fetch-libghostty.sh` — commit SHA 固定で libghostty をビルド (Ghostty から `zig build`、Sessylph のビルドガイド参考)
- [ ] `vendor/libghostty/` に成果物を配置 (`include/ghostty.h`, `lib/libghostty.a`)、`.gitignore`
- [ ] Xcode: `HEADER_SEARCH_PATHS`, `LIBRARY_SEARCH_PATHS`, `OTHER_LDFLAGS` を追加
- [ ] `Bridging/Kanbario-Bridging-Header.h` 追加、Build Settings の Objective-C Bridging Header を設定
- [ ] `Kanbario/GhosttySurface.swift` — ghostty_init → surface_new → write / set_size / encode_key
- [ ] `Kanbario/GhosttyNSView.swift` — NSView + CAMetalLayer、NSViewRepresentable
- [ ] TaskDetailView の `sessionPane` を GhosttyNSView で置き換え、以下を**削除**:
  - `AppState.sessionLogs`, `sessionExitCodes`, `appendLog`, `stripANSI`, `sendInput`
  - TaskDetailView の `sessionPane`, `submitInput`, `@State inputText`
  - `SessionManager.write` は GhosttyNSView からの key 入力で使うので残す
- [ ] 検証: Start → 詳細画面に色つき terminal、カーソル / リサイズ動作、2 タスク同時起動で切替正しく

### 既知のリスク

- libghostty API 不安定 → SHA 固定 + C 呼び出しを `Ghostty*.swift` に隔離
- zig build が重い → `fetch-libghostty.sh` は 1 度だけ走らせて成果物は `.gitignore`
- Xcode target 設定の調整 (App Sandbox は既に OFF なので新たな制約なし)

---

## その後: Milestone C 後半 (hook 統合)

libghostty が入ってから着手。

- [ ] Xcode に 2 つ目の target (Swift Command Line Tool `kanbario`) を追加 — pbxproj 編集
  - 現 pbxproj は PBXFileSystemSynchronizedRootGroup 方式なので、`CLI/` 用に同じ方式で追加すれば自動登録される
- [ ] `CLI/main.swift` — Unix socket に hook event を送る Swift バイナリ
- [ ] `Resources/bin/claude` — bash shim、`KANBARIO_SURFACE_ID` が set なら `--settings` で hook JSON 注入 (spec.md §6.1)
- [ ] App target に Copy Files build phase を追加 — CLI バイナリと shim を `Resources/bin/` に埋め込む
- [ ] `Kanbario/HookReceiver.swift` — NWListener で Unix socket を listen
- [ ] AppState に hook イベント別のハンドラ
  - `SessionStart` → 既存の同期遷移を確定
  - `Stop` → `sessions.activity = needsInput` (詳細画面にバッジ)
  - `UserPromptSubmit` / `PreToolUse` → `running` に戻す
  - `SessionEnd` → 既存のプロセス exit 経路と冗長化

---

## 低優先の後回し

- **GRDB 導入**: event log が必要になった時点で
- **ADR 0002**: Milestone 順序反転の意思決定を書き残すと後から読んだ時に親切
- **Settings UI**: asdf / mise ユーザー向けに extra PATH / claude path を設定できるようにする
- **暫定 UI の磨き込み (auto-follow トグル、ログ tail サイズ、コピー UX)**: **捨てる前提なのでやらない**

---

## 参照

- [docs/spec.md](spec.md) — 仕様全文
- [docs/adr/0001-kanban-drag-drop-swiftui-only.md](adr/0001-kanban-drag-drop-swiftui-only.md)
- cmux: https://github.com/manaflow-ai/cmux (libghostty 先行実装、最重要)
- Sessylph: https://zenn.dev/saqoosha/articles/sessylph-libghostty-claude-code-terminal
- Ghostling: https://github.com/ghostty-org/ghostling (libghostty 最小 init)
