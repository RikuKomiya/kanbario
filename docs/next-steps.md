# Next Steps (2026-04-20 時点)

MVP 完成までの次アクション備忘録。spec.md §8 のマイルストーン計画を
実装しながら更新した版。**次のセッションはここから読む**こと。

---

## 現状サマリ

- 現 branch: `main` (PR #1 = merge commit `a46c28a` で `feat/milestone-d-libghostty` を取り込み済み)
- Milestone A/B/C前半/D 完了 (D は cmux 完全踏襲)
- libghostty 経由で claude 起動 → 色つきターミナル描画 → キー入力 / IME / マウス selection / スクロール が動く
- 暫定 sessionPane / AppState.sessionLogs / stripANSI は削除済み
- **次の着手先は Milestone C 後半 (hook 統合)** — 本ファイル §「Milestone C 後半」のチェックリスト参照

### 動く end-to-end フロー

1. toolbar の Choose Repo で git リポジトリを選択
2. New Task (⌘N) でタスク追加 (planning 列)
3. 詳細画面で Start → wt が worktree を作成、libghostty が claude spawn、inProgress へ
4. **色つきターミナル**で claude と直接対話 (キーボード入力 / 日本語入力 / マウス selection / スクロール)
5. Stop ボタンで `ghostty_surface_request_close` (SIGHUP)
6. プロセス exit で close_surface_cb → review に自動遷移、review → done drag で wt remove + teardown

### 残タスク / 改善候補

- **hook 統合未実装**: claude の状態バッジ (needsInput / running / reasoning) が出ない → Milestone C 後半で実装
- **action_cb が stub**: `cellSize` が 0 固定 (IME 候補 window の初期位置がずれる可能性)。`GHOSTTY_ACTION_CELL_SIZE` 通知を受ければ解消
- **Focus 復旧経路が簡素**: cmux にある `requestPointerFocusRecovery` 相当は未移植。split / tab 無しの kanbario MVP では問題になりにくい
- **マウスホバー / command-click で open-in-editor**: NSTrackingArea + `ghostty_surface_quicklook_word` 経由は未移植 (MVP では nice-to-have)

---

## 方針: cmux 完全踏襲 (2026-04-19 決定)

cmux (https://github.com/manaflow-ai/cmux) の実装を確認した結果、libghostty と
hook 統合のエッジケース対応が想像以上に重厚だったため、**独自の最小化を試みず
cmux を写経する**方針に確定。

**Why:** libghostty の modifier 左右判定 (`NX_DEVICELSHIFTKEYMASK` 系)、
clipboard の NSPasteboard 分岐、claude shim の stale socket detection などは
削ると必ず踏む地雷。cmux は 14k★ で実戦投入済みの先例なので、差分を作ると
そのぶんバグの当事者になる。

**How to apply:**
- 実装時は cmux の該当ファイルをまず確認してから書く
- 変数名 / 関数名の prefix は `cmux*` → `kanbario*`、環境変数は `CMUX_` → `KANBARIO_` に機械置換
- cmux 依存の外部 package (`Sentry`, `Bonsplit`) と独自 config は削除、その周辺コードも落とす
- **それ以外は構造・ロジックを変えない**

---

## マイルストーン順序 (spec.md §8 から反転)

spec.md §8 は C(hook) → D の順だが、TUI ノイズ解消が最優先なので **D → C 後半** に反転。

- **Milestone D**: libghostty 描画 (このセッションで着手)
- **Milestone C 後半**: hook 統合 (D 完了後)

暫定 sessionPane は libghostty 導入時に**丸ごと捨てる**前提 — 暫定 UI の磨き込みはやらない。

---

## Milestone D: libghostty 描画 (完了)

### D-a: GhosttyKit.xcframework 取得基盤 (完了)

- [x] `git submodule add https://github.com/manaflow-ai/ghostty.git ghostty` — **cmux の fork を同 SHA `3b684a08...` に pin** (cmux が動作確認済みの組み合わせを踏襲)
- [x] `scripts/ensure-ghosttykit.sh` — cmux から移植、`CMUX_` → `KANBARIO_` 置換、cache dir を `~/.cache/kanbario/ghosttykit/<sha>/` に変更
- [x] `scripts/ensure-zig.sh` — **cmux にはないがCI 踏襲**。`https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz` を `~/.cache/kanbario/zig/0.15.2/` に展開 (brew の 0.16 は ghostty の `requireZig(0.15.2)` に不適合。cmux CI 相当のロジック)
- [x] `Kanbario/ghostty.h` — `#include "ghostty/include/ghostty.h"` の 1 行 bridge header
- [x] `.gitignore` — `GhosttyKit.xcframework` (symlink) と ghostty submodule 内の build intermediates を除外
- [x] `./scripts/ensure-ghosttykit.sh` で `GhosttyKit.xcframework` symlink 生成 (`xcodebuild -downloadComponent MetalToolchain` が前提)

### D-b: Xcode 統合 (完了)

- [x] `GhosttyKit.xcframework` を Xcode の Frameworks にリンク (pbxproj 直編集、**Embed は OFF** — static archive なので codesign 失敗の元)
- [x] Build Settings: `SWIFT_OBJC_BRIDGING_HEADER = Kanbario/ghostty.h` + `FRAMEWORK_SEARCH_PATHS` / `HEADER_SEARCH_PATHS = $(SRCROOT)`
- [x] `OTHER_LDFLAGS = -lc++` (libghostty.a の VT パーサは C++ 実装で `__gxx_personality_v0` を要求)
- [x] xcframework 参照は SOURCE_ROOT の symlink 経由 (cache SHA 固定を回避)
- [ ] Run Script で `./scripts/ensure-ghosttykit.sh` を自動実行するフェーズは**未設定** (現状は手動実行前提)

### D-c: Swift 統合 — cmux 写経 (完了)

cmux `Sources/GhosttyTerminalView.swift` 12,651 行のうち **約 20 % を kanbario 側に
写経**。写経範囲は各 commit メッセージに cmux の行番号と共に記録してある。

- [x] `Kanbario/GhosttyApp.swift` — singleton + runtime callback (§1652-1847、§56-102 modifier)
- [x] `Kanbario/GhosttyTerminalView.swift` 骨格 — TerminalSurface + GhosttyNSView + CAMetalLayer + viewDidMoveToWindow / layout
- [x] キー入力 (keyDown / flagsChanged、§6607-7130 相当を簡潔化)
- [x] IME / NSTextInputClient (§11737-12189、日本語入力動作)
- [x] マウス / スクロール (§7440-7475 / §8299-8347)
- [x] `Kanbario/SessionManager.swift` → `ClaudeSessionFactory` (enum、PTY 所有を libghostty に移譲、264 → 100 行)
- [x] `TaskDetailView.sessionPane` → `GhosttyTerminalView`、暫定 UI コードをすべて削除

### D 完了条件 (2026-04-19 クリア)

- [x] Start → 詳細画面に色つき terminal、カーソル / リサイズ動作
- [x] 日本語入力 (Kotoeri 等) で preedit overlay がカーソル位置に追従
- [x] マウスで text selection / 右クリック / スクロール (trackpad momentum 含む)
- [x] 実機で end-to-end 動作確認済み (2026-04-19)

---

## Milestone C 後半: hook 統合 (D の後)

cmux の shim / CLI を完全踏襲。

- [ ] Xcode に 2 つ目の target (Swift Command Line Tool `kanbario`) を追加
  - 現 pbxproj は PBXFileSystemSynchronizedRootGroup 方式なので、`CLI/` 用に同じ方式で追加すれば自動登録される
- [ ] `CLI/main.swift` — cmux `CLI/cmux.swift` から `claude-hook` サブコマンド部分を抜粋、Sentry 周辺を削除
- [ ] `Resources/bin/claude` — cmux shim を copy、`CMUX_` → `KANBARIO_` 全置換、bundle id 参照を kanbario に
- [ ] `Resources/bin/kanbario` — App の CLI target バイナリを配置 (shim から呼ばれる)
- [ ] App target に Copy Files build phase を追加 — CLI バイナリと shim を `Resources/bin/` に埋め込む
- [ ] `Kanbario/HookReceiver.swift` — cmux の hook receiver 部分を抜粋、NWListener で Unix socket を listen
- [ ] AppState に hook イベント別のハンドラ (6 種全部、spec.md §6.1 参照)
  - `SessionStart` → 既存の同期遷移を確定
  - `Stop` → `sessions.activity = needsInput` (詳細画面にバッジ)
  - `SessionEnd` → 既存のプロセス exit 経路と冗長化
  - `UserPromptSubmit` / `PreToolUse` → `running` に戻す
  - `Notification` → macOS 通知

---

## 低優先の後回し

- **GRDB 導入**: event log が必要になった時点で
- **ADR 0002**: Milestone 順序反転の意思決定を書き残すと後から読んだ時に親切
- **ADR 0003**: cmux 完全踏襲方針の意思決定記録
- **Settings UI**: asdf / mise ユーザー向けに extra PATH / claude path を設定できるようにする
- **暫定 UI の磨き込み (auto-follow トグル、ログ tail サイズ、コピー UX)**: **捨てる前提なのでやらない**
- **自前 GhosttyKit.xcframework release**: zig build が遅すぎて辛くなったら、自 fork を立てて prebuilt tar.gz を GitHub Release に置き、`download-prebuilt-ghosttykit.sh` を追加する (cmux の二段構え方式)

---

## 参照

- [docs/spec.md](spec.md) — 仕様全文
- [docs/adr/0001-kanban-drag-drop-swiftui-only.md](adr/0001-kanban-drag-drop-swiftui-only.md)
- **cmux** (最重要、完全踏襲元): https://github.com/manaflow-ai/cmux
  - `scripts/ensure-ghosttykit.sh` — libghostty cache + ranlib refresh
  - `Sources/GhosttyTerminalView.swift` — NSView + Metal layer の実装
  - `Resources/bin/claude` — shim スクリプト
  - `CLI/cmux.swift` — hook CLI の実装
- Sessylph: https://zenn.dev/saqoosha/articles/sessylph-libghostty-claude-code-terminal
- Ghostling: https://github.com/ghostty-org/ghostling (libghostty 最小 init)
