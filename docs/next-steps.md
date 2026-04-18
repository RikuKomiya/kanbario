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

## Milestone D: libghostty 描画 (着手中)

### D-a: GhosttyKit.xcframework 取得基盤 (ほぼ完了)

- [x] `git submodule add https://github.com/manaflow-ai/ghostty.git ghostty` — **cmux の fork を同 SHA `3b684a08...` に pin** (cmux が動作確認済みの組み合わせを踏襲)
- [x] `scripts/ensure-ghosttykit.sh` — cmux から移植、`CMUX_` → `KANBARIO_` 置換、cache dir を `~/.cache/kanbario/ghosttykit/<sha>/` に変更
- [x] `scripts/ensure-zig.sh` — **cmux にはないがCI 踏襲**。`https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz` を `~/.cache/kanbario/zig/0.15.2/` に展開 (brew の 0.16 は ghostty の `requireZig(0.15.2)` に不適合。cmux CI 相当のロジック)
- [x] `Kanbario/ghostty.h` — `#include "ghostty/include/ghostty.h"` の 1 行 bridge header
- [x] `.gitignore` — `GhosttyKit.xcframework` (symlink) と ghostty submodule 内の build intermediates を除外
- [ ] `./scripts/ensure-ghosttykit.sh` を手動実行 → `GhosttyKit.xcframework` symlink が張られることを確認 (**実行中**)

### D-b: Xcode 統合

- [ ] `GhosttyKit.xcframework` を Xcode の Frameworks にドラッグして Embed & Sign
- [ ] Build Settings: Objective-C Bridging Header = `Kanbario/ghostty.h`
- [ ] Build Phase に "Run Script: `./scripts/ensure-ghosttykit.sh`" を Compile Sources の**前**に追加 (input/output files を宣言しないと毎回走るので注意)
- [ ] App Sandbox は既に OFF なので entitlements 変更不要
- [ ] 空の Swift ファイルから `ghostty_init()` を呼んでリンクが通ることを smoke test

### D-c: Swift 統合 — cmux 写経

**重要な設計判断 (2026-04-19)**: libghostty は `ghostty_surface_new` で自前で
`fork + execve` まで行う設計。よって既存 `SessionManager.startClaude()` の
openpty + Foundation.Process spawn と責務が二重化するので、**PTY 所有権を
libghostty に移譲**する (cmux 方式踏襲)。SessionManager は「surface → task の
マッピング」「終了コード伝搬」程度の薄い層に縮退。

cmux `Sources/GhosttyTerminalView.swift` は 12,651 行だが **約 20 % のみ写経**。
行番号は 2026-04-19 時点の cmux main (SHA TBD、写経直前に再確認) の目安:
- 残す: §56-102 (左右 modifier 判定 `cmuxGhosttyModifierActionForFlagsChanged`) /
  §1652-1847 (`GhosttyApp.initializeGhostty`) / §4444-4598 (`TerminalSurface.createSurface`) /
  §4600-4648 (`updateSize`) / §5201-7230 (`GhosttyNSView` の makeBackingLayer / setup / keyDown / flagsChanged / modsFromFlags) /
  §11739-12200 (NSTextInputClient extension、IME)
- 削る: §154-870 (`GhosttyPasteboardHelper` 画像系) / §875-1025 (TerminalOpenURL / KeyboardCopyMode) /
  §5500-6400 (action_cb の巨大 switch、最小 stub で OK) / §8784+ (scrollview / notification ring) /
  Sentry / Bonsplit 依存、CmuxConfig、AppleScript、DEBUG probe

具体タスク:
- [ ] `Kanbario/GhosttyApp.swift` — `GhosttyApp.initializeGhostty` 本体 (§1652-1847 相当) + runtime callback 群 (clipboard は text/plain のみ、画像 branch 削除)。inline config は `macos-background-from-layer = true\nshell-integration = none`
- [ ] `Kanbario/GhosttyTerminalView.swift` — 上記残す範囲を写経 (写経時に `cmux*` → `kanbario*` / `CMUX_` → `KANBARIO_` / Sentry・Bonsplit 除去)
- [ ] `Kanbario/SessionManager.swift` — **責務縮退**: `startClaude` の openpty / Process.run を削除、代わりに `ghostty_surface_new` 呼び出し時に `command = "claude"` / `env_vars` / `working_directory = worktreeURL.path` を渡す。`close_surface_cb` で終了検知して `finish(exitCode:)` 呼び出し
- [ ] `TaskDetailView` の `sessionPane` を `GhosttyTerminalView` に差し替え、以下を**削除**:
  - `AppState.sessionLogs`, `sessionExitCodes`, `appendLog`, `stripANSI`, `sendInput`
  - TaskDetailView の `sessionPane`, `submitInput`, `@State inputText`
  - SessionManager.write (libghostty 内で PTY 書き込み完結するため不要)

### D 完了条件

- Start → 詳細画面に色つき terminal、カーソル / リサイズ動作
- 2 タスク同時起動で surface 切替が正しい (surface の lifecycle が worktree と一対一)

### 既知リスク

- `zig build` が 3-5 分かかる → cmux と同じく `~/.cache/kanbario/ghosttykit/<sha>/` にキャッシュ、ranlib refresh も踏襲
- GhosttyTerminalView の写経ミス → cmux の同名ファイルを常に参照、差分は `cmux*` → `kanbario*` の機械置換だけに抑える

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
