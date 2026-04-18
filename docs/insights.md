# kanbario 開発ノート — Insights 集

> kanbario を Claude Code と一緒に実装する過程で抽出した学びの記録。
> 後から読み返して「なぜこの設計にしたか」「どのパターンが有効か」を思い出すためのリファレンス。
> 順番は topical (分野別)。文脈 → 学び → 応用可能性 の順で記載。

---

## 目次

1. [Swift 言語の慣習](#1-swift-言語の慣習)
2. [macOS / Xcode 固有](#2-macos--xcode-固有)
3. [SwiftUI + Observable](#3-swiftui--observable)
4. [Swift Concurrency (async/await)](#4-swift-concurrency-asyncawait)
5. [アーキテクチャ設計判断](#5-アーキテクチャ設計判断)
6. [外部ツール統合 (libghostty / worktrunk / Claude)](#6-外部ツール統合)
7. [テスト戦略](#7-テスト戦略)
8. [Git / 開発ワークフロー](#8-git--開発ワークフロー)
9. [Learn by Doing で直面した落とし穴](#9-learn-by-doing-で直面した落とし穴)

---

## 1. Swift 言語の慣習

### 1.1. `@_silgen_name` は Bridging Header 回避の軽量 FFI

**文脈**: kanbario の `PTY.swift` で `openpty(3)` を呼ぶ必要があった。`openpty` は `<util.h>` 宣言で、Darwin module には含まれない。通常は Bridging Header を作って `#include <util.h>` するが、Xcode プロジェクト設定を触る手間がある。

**学び**: `@_silgen_name("openpty")` を Swift 関数に付けると、**Bridging Header なしで C 関数を直接リンクできる**。

```swift
@_silgen_name("openpty")
private func c_openpty(_ amaster: UnsafeMutablePointer<Int32>,
                       _ aslave: UnsafeMutablePointer<Int32>,
                       _ name: UnsafeMutablePointer<CChar>?,
                       _ termp: UnsafePointer<termios>?,
                       _ winp: UnsafePointer<winsize>?) -> Int32
```

**応用**: util.h のような「Darwin には載っていないが標準的な POSIX API」を叩く時の一番軽い手段。**欠点**: シンボル名ミスがリンカエラーでしか検出されない (コンパイラはチェックしない)。

### 1.2. `winsize` と `termios` は Darwin から来る

`import Darwin` すると struct 定義が入るので、C の構造体を Swift から直接リテラル構築できる:

```swift
var ws = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
```

低レベル API を扱う時の強力なメリット。`import Foundation` だけでは取れない。

### 1.3. Swift concurrency の `Task` とドメインの `Task` の名前衝突

**文脈**: `Models.swift` に `struct Task` を定義していたが、`SessionManager.swift` で `Task.detached { ... }` を使った瞬間にコンパイルエラー。Swift 標準の `_Concurrency.Task` と名前衝突していた。

**学び**: Swift concurrency の `Task` は標準ライブラリ全域に暗黙的に import されている。**ドメインオブジェクトに `Task` と名付けない** が鉄則。kanbario では `TaskCard` にリネーム。

**類似の予約名**:
- `id` (Identifiable を実装するとき)
- `body` (View プロトコル要求)
- `description` (Codable / CustomStringConvertible)

**一般原則**: 新しい View や Observable を書き始める時は、State 変数の名前を `titleText`, `bodyText` のように **suffix 付きで命名する** 癖が安全。

### 1.4. `View.body` と `@State var body` の衝突

**文脈**: `NewTaskSheet` で task 内容のフィールドを `@State var body` と書いた → `'body' が redeclaration` のエラー。

**学び**: `body` は `View` プロトコルが要求する computed property 名。同じ構造体内に `body` という別プロパティを定義できない。

**解決**: `bodyText` のように suffix を付ける。あるいは `promptText` のように役割で命名する。

### 1.5. Substring と String の違い

**文脈**: `id.uuidString.prefix(6)` は型が `Substring`。これを長期保持すると元の String 全体がメモリに残り続ける。

**学び**: `Substring` は元 String のビュー。文字列補間 `"\(substring)"` では自動変換されるが、**長期保持するなら `String(...)` でラップする** 癖を付けると安全。

### 1.6. `guard let ... else return` の 2 段構え

**文脈**: `moveTask(id:to:)` で「対象タスクが存在し、かつ遷移が許可されている」ことを事前チェックしたい。

**学び**: `guard` を積み重ねることで **正常系のコードが左寄せ** に残る (`if` のネストと対照的)。英語圏ではこれを "happy path stays on the left" と呼ぶ。

```swift
guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
guard tasks[idx].status.canTransition(to: newStatus) else { return }
tasks[idx].status = newStatus  // happy path, no nesting
```

### 1.7. 値型 struct の配列内 mutation は index 経由で

**文脈**: `tasks[idx]` は `TaskCard` (struct)。`var task = tasks[idx]; task.status = X` は **ローカルコピーを変えているだけで配列本体は変わらない**。

**学び**: Swift では配列の subscript 経由のプロパティ代入は compiler が in-place で更新してくれる:

```swift
// ❌ これは動かない (silent failure)
var task = tasks[idx]
task.status = newStatus

// ✅ これで配列本体が変わる
tasks[idx].status = newStatus
```

コンパイルは通るのでバグとして露呈するまで気付きにくい。**「値型なら index 経由で直接代入」** が合言葉。

### 1.8. `nonisolated static func` は Swift 6 でよく書くパターン

**文脈**: `PTY.openpty()` を actor `SessionManager` から呼んだら「main actor-isolated static method cannot be called」エラー。

**学び**: Swift 6 ではデフォルトで main-actor 隔離がかかる (プロジェクト設定次第)。副作用のない enum / struct の static method でも `nonisolated` 宣言が必要になる:

```swift
enum PTY {
    nonisolated static func openpty(...) throws -> Handles { ... }
}
```

---

## 2. macOS / Xcode 固有

### 2.1. Xcode 26 の Synchronized Folder

**文脈**: Xcode 14 以前は `.pbxproj` にファイル参照を 1 つ 1 つ登録する必要があった。`Kanbario/PTY.swift` を置いても project に認識されず、Finder からドラッグしないといけなかった。

**学び**: Xcode 15+ の **synchronized group** は物理フォルダを監視して自動的にビルド対象にする。**ファイルを置けば認識される** = 現代 JavaScript / Rust プロジェクトと同じ感覚で Swift を書ける。

**副作用**: `xcodeproj` Ruby gem のような古いツールは synchronized group を認識せずエラーになる。**ツールが持つ前提と現実の乖離** に注意。

### 2.2. `.pbxproj` を人間が触れない事実が Apple エコシステム特有

Android Studio の `build.gradle` や Node の `package.json` は人間が読み書きする前提。iOS/macOS だけ「プロジェクト定義を IDE が独占する」文化で、XcodeGen / Tuist はこの文化に対する市民運動的ツール。

### 2.3. TypeScript 文脈での XcodeGen の対応物

`tsconfig.json` や `package.json` を手で書く感覚に近い。TypeScript から来る人にとって **素の Xcode プロジェクト管理は違和感が強い**。XcodeGen は「慣れた YAML 文化」への橋渡し。

### 2.4. XcodeGen を MVP 段階で入れない判断

素の `.xcodeproj` で設定項目の名前を学ぶ機会を残すため、MVP の初期は素の Xcode UI を使う。Phase 2 以降で、プロジェクトが大きくなってきたら XcodeGen を検討。

### 2.5. App Sandbox は kanbario には本質的に無理

**文脈**: Xcode テンプレートは `ENABLE_APP_SANDBOX = YES` がデフォルト。しかし kanbario は外部プロセス (`claude`, `wt`, `git`, bash) の spawn と任意ディレクトリへのアクセスが必須。

**学び**: App Sandbox は kanbario の性質と本質的に両立しない。**開発者向け統合ツール** (Sublime Text / VS Code / Cursor 等) はみな sandbox なし。副作用として **Mac App Store 配布は不可**、Developer ID + notarization での直接配布のみ。

**検出**: テストが「Process.run() が silently fail する」形で発見される。sandbox 内では git / wt などの外部バイナリ起動が拒否される。

### 2.6. macOS の TCC (Transparency, Consent, Control) の開発体験

**文脈**: `~/Desktop/Kanbario/` に Xcode プロジェクトを作ったが、Claude Code から `ls ~/Desktop` が「Operation not permitted」。

**学び**: Desktop / Documents / Downloads / iCloud Drive は標準で各アプリに非公開。**「~/mywork や ~/projects のような自前の作業ディレクトリを PATH の外に持つ」** のが現代の macOS 開発の基本形。

### 2.7. Xcode の `⌘R` と `⌘B` の違い

- `⌘B`: build のみ (成果物を作る)
- `⌘R`: build + launch + debugger attach

`⌘R` で起動するとアプリがクラッシュしても **Xcode がスタックトレースを見せてくれる** ので開発中は基本 `⌘R`。

### 2.8. Ad-hoc 署名の Gatekeeper 警告

ad-hoc 署名の macOS アプリは Gatekeeper に警告されることがある。Xcode 経由で起動する限りは警告されない。直接 Finder からダブルクリックすると「開発元が未確認です」で止まる。

### 2.9. Xcode の新しい Swift Testing (`@Test`)

従来の XCTest との違い:
- `@Test("...")` で日本語の説明を書ける
- `#expect` でコンパクトなアサーション
- パラメータ化テストが楽
- Xcode 16 以降のデフォルトなので、新規プロジェクトは Swift Testing 一択で OK

### 2.10. `keyboardShortcut(.defaultAction)` と `.cancelAction`

SwiftUI の魔法: Save ボタンに `.defaultAction` を付けると自動で Enter キーと青いデフォルトボタン装飾がつく。Cancel に `.cancelAction` を付けると自動で Esc キーが割り当てられる。**SwiftUI が macOS の HIG (Human Interface Guideline) を知っている**。

### 2.11. Sandbox なしでも `xcuserdata` は ignore すべき

- `xcuserdata/` は個人の IDE 設定 (開いてるファイル、ブレークポイント位置等)
- `DerivedData/` はビルドキャッシュ
- `.DS_Store` は Finder のメタデータ

どれも git に入れない。

---

## 3. SwiftUI + Observable

### 3.1. `@Observable` + 値型配列の組み合わせ

**文脈**: Rust / JavaScript だと「変更通知を配列に発生させる」ために custom setter / event emitter を書く。

**学び**: Swift 5.9+ の Observation framework は **配列内の struct を index 経由で変えても SwiftUI View が更新される**。配列全体を差し替えなくて良い = パフォーマンス的にも有利。

```swift
@Observable class AppState {
    var tasks: [TaskCard] = []
}

// View 更新: tasks[idx].status = .inProgress  // これで十分
```

### 3.2. `@State` で reference type を持つ意味

**文脈**: `@State private var sessionManager = SessionManager()` (SessionManager は actor)。

**学び**: `@State` は本来値型用だが、actor (= reference type、Sendable) を入れても動く。ただし View が再生成されるたびに新しい instance が出来てしまう懸念がある。View が単独で寿命 = アプリと同じ ならセーフ。

**Phase 2 で複数画面になったら** `@Observable class AppState` に昇格させるのが定石。

### 3.3. `@Environment` の 2 種類

- `@Environment(AppState.self)`: 親が `.environment(appState)` で注入したオブジェクトの取得 (型指定)
- `@Environment(\.dismiss)`: SwiftUI 組み込みの環境値の取得 (KeyPath 指定)

同じ `@Environment` でも型 vs KeyPath で用途が分かれる。

### 3.4. `canTransition` を UI ではなく Model で enforce する意義

**文脈**: Kanban drag-and-drop の遷移ルールを UI 側で検証するか、Model 側で検証するか。

**学び**: `moveTask` 側で `canTransition` チェックを持たせると、**どの UI コードから呼んでも状態機械が守られる**。SwiftUI の drag-and-drop だけでなく、将来追加する keyboard shortcut / AppleScript / MCP / CLI からの呼び出しでも同じ不変条件が成立する。

**一般原則**: **「モデルが自分を守る」設計** は長期メンテナンス性の鍵。

### 3.5. UTType の `exportedAs:` の地味な重要性

**文脈**: Kanban の drag-and-drop で TaskCard を運ぶ。

**学び**: `app.kanbario.task-drag` という独自 UTI を宣言することで、**他のアプリに kanbario のタスクをドロップしても意図しない動作が起きない**。例えば `UTType.data` でドラッグを表現していたら、Finder に落として訳のわからない挙動になり得る。**ドラッグ型は常にアプリ固有の UTI を切る** は macOS 開発のマナー。

### 3.6. mutation-on-every-write の永続化パターンの綺麗さ

**文脈**: JSON ファイル永続化を実装するとき、どこでファイル書き込みをトリガするか。

**学び**: addTask / moveTask / deleteTask の末尾に `save()` を置くだけで「UI 操作 → 自動的にディスクへ」が成立する。別言語だと observer / subscriber を噛ませる必要があるところ、Swift は **mutation の観点からロジックを書けば永続化が副次的に成立する** 構造が取れる。

---

## 4. Swift Concurrency (async/await)

### 4.1. `withCheckedThrowingContinuation` は古い API を async にする万能ツール

**文脈**: `Process.waitUntilExit()` は同期ブロッキングで main thread を固まらせる。`Foundation.Process.terminationHandler` はコールバックベース。

**学び**: Foundation の大半はまだコールバックベース。これを async/await に橋渡しする `Continuation` パターンを 1 回自分で書けば、どんな callback API も `async` 化できる:

```swift
try await withCheckedThrowingContinuation { cont in
    p.terminationHandler = { proc in
        if proc.terminationStatus == 0 { cont.resume() }
        else { cont.resume(throwing: ...) }
    }
    try p.run()
}
```

**応用**: kanbario で libghostty を叩く時 (Phase D) も、Claude Code hook を受ける時も、このパターンで書ける。

### 4.2. `for await` + `AsyncStream` が PTY のような「終端がある無限ストリーム」に綺麗

**文脈**: PTY の stdout はバイトが続々流れて、子プロセス終了で EOF になる。

**学び**: Combine の publisher だと `sink { }` + cancellable 管理が必要だが、AsyncStream + `for await` は **「ストリームが close されたらループを抜けて次に進む」** が構文レベルで表現できる。async/await の最大の利点の 1 つ。

```swift
for await chunk in session.bytes {
    // EOF が来るとここを抜ける
}
// 次の処理へ自然に流れる
```

### 4.3. AsyncStream の Continuation 抱え込みパターン

**文脈**: SessionManager の LiveSession が AsyncStream と Continuation の両方を保持。

**学び**: Swift で「publisher/subscriber を 1 つのクラスにまとめる」時の定番。Combine の PassthroughSubject より軽量だが、**`finish()` を呼び忘れるとストリームが閉じず subscriber 側が永遠に待つ** ので注意。

### 4.4. Rust と Swift の async モデルの類似

一時検討した Rust daemon 路線で得た知見 (最終的に Swift 単一化したが有用):

- Rust の `tokio::spawn` と Swift の `Task { }` は似た概念
- Rust の `Arc<AppState>` と Swift の actor の共有はどちらも「誰が何を保持しているか」を型で追わせる
- Rust の `broadcast::channel` と Swift の AsyncStream は 1-to-many fanout の基本パターン

Rust の `spawn_blocking` (blocking call を別スレッドに退避) に相当するのが Swift の `Task.detached` + 非 await な C 関数呼び出し。

---

## 5. アーキテクチャ設計判断

### 5.1. 「技術的に可能」と「その選択が正しい」は別問題

**文脈**: 初期は Rust daemon + Swift UI で IPC を挟む設計だったが、調査の結果「Swift 単独で全機能実装可能」と判明。

**学び**: 単言語化すれば IPC 層が消え、バージョン差分もシリアライズも存在しなくなる。エンジニアリング上の最小コスト解は常に「言語を 1 つにする」側に寄る。**複数言語を選ぶのは学習・ecosystem・crash isolation など明確な理由がある時だけ** というのは重要な設計原則。

### 5.2. cmux の Go が hot path 外な設計哲学

cmux は「ローカル体験はすべて Swift」「リモート接続という特殊ケースだけ別言語 (Go)」と境界を置いている。つまり **「単言語で済ませるのを努力し、境界が明確な領域だけ別言語を足す」** 方針。

kanbario が真似するなら、まず Swift で全部書き、orchestration の特定領域 (例えば MCP 連携) だけ後から Rust に切り出す方が cmux と同じ思想になる。

### 5.3. cmux の polyglot 構成は「右の道具で右の仕事」

cmux は複数言語を使うが境界が明確:
- Swift (ローカル UI + libghostty、8MB): hot path
- Go (リモート SSH デーモン): not hot path
- TypeScript (Web サイト): マーケティング
- Python (tests + scripts): 検証・ビルドツール

**一般原則**: 「この言語はここだけ」と境界を明文化すると破綻しない。

### 5.4. 今この決定を後で覆せるコスト

**文脈**: Rust daemon vs Swift 単独の判断時の考慮。

**学び**: IPC を挟む設計は後から外すのが辛い (レイヤ全廃になる)。逆に **Swift 単独で書いておいて後で一部を Rust に切り出すのは容易** (既存 Swift コードは残して差し替える部分だけ Rust)。**判断に迷う時は単純側 (Swift 単独) に倒しておく** 方がリスクが小さい。

### 5.5. 「ライブラリとして組み込む」vs「プロセスとして呼ぶ」

**文脈**: worktree 管理を SwiftGit2 で組み込むか、`wt` CLI を subprocess で呼ぶか。

**学び**:
- 組み込み: 型安全・速度・バージョン一致
- subprocess: 疎結合・置換可能性・ユーザー自身も CLI で使える

worktrunk を subprocess で呼ぶと、**ユーザーが kanbario を使わず `wt` だけで作業する日** も守れる (kanbario が落ちても作業環境は壊れない)。これは「アプリが壊れたらデータも壊れる」ロックインを避ける重要な設計哲学。

### 5.6. 「何を自分で書き、何を既存ツールに任せるか」の判断軸

1. その機能が独立の価値を持つか
2. 既存ツールが活発にメンテされているか
3. 離脱コストは低いか

**worktree 管理** は (1) 独立した価値 (2) worktrunk がアクティブ (3) 直接 `git worktree` に戻せる → 委譲すべき。

一方 **PTY 管理** は kanbario の中核価値と密結合なので自前実装すべき。

### 5.7. 「双方向 IPC」と「イベント通知 IPC」は実装コストが桁違い

**文脈**: 最初 Rust daemon IPC を却下した理由 (重い)。しかし cmux の Claude hook 統合は軽量 IPC を使っている。

**学び**: 双方向・高頻度・バイナリストリーム IPC は重い (タグ付きフレーム codec、再接続、シリアライズエラー処理)。片方向・低頻度・小 JSON IPC は 50 行で書ける。**「IPC = 重い」と思い込むと設計の自由度を失う**。

### 5.8. Claude Code hooks システムの戦略的価値

Claude Code は hook を「ユーザーが `.claude/settings.json` で書くもの」として提供しているが、cmux は **`--settings` フラグで JSON を直接注入**して追加設定に昇格させている。これは「Claude Code の利用者」ではなく「Claude Code を組み込む開発者」の視点で hook を使う発想。kanbario も同じ立ち位置なので、このパターンをそのまま採用。

### 5.9. 「state を何粒度で持つか」の設計

**文脈**: cmux は shell 粒度 (promptIdle / commandRunning) しか持たない。

**学び**: 粒度の分離は「誰がその情報を必要とするか」で決める:
- Kanban UI → Task 粒度
- terminal 表示 → shell 粒度
- 再起動時の復旧 → process 粒度

kanbario は 3 層別々に持つ。これは UX 要求の違いから来る。

### 5.10. 「ラッパーで実行ファイルを置き換える」は PATH 時代の強力な設計パターン

**文脈**: cmux が `claude` を自前ラッパーで上書きする仕組み。

**学び**: プラグインポイントを持たないツールでも無理やり hook を差し込める テクニック。git の hook や `/usr/libexec/{tool}` 系ツールで古くから使われている手法で、**自分が改修できないバイナリを制御するときの最終兵器**。

### 5.11. 「整理しすぎない」が Swift プロジェクトの美学

**文脈**: cmux の `Sources/` はほぼフラット (40+ ファイル、サブディレクトリは feature cluster のみ)。

**学び**: 他言語 (Rust / TypeScript) から来ると「まず階層を作る」が反射になるが、Swift + Xcode 環境では **flat → 必要に応じて階層化** の方が idiomatic。階層化は "premature organization" として悪手になりやすい。

**判断基準**: 1 機能で 5 ファイル以上が束になった時が階層化のタイミング。cmux では `Find/`, `Panels/`, `Update/` のみ。

### 5.12. Bridging Header と entitlements がルート直置きの意味

これらは **Xcode のビルド設定が参照するパス**。深い階層に置くと Build Settings の相対パスがずれて事故る。**「プロジェクト設定が直接参照するファイルはルート」** が macOS 開発の暗黙ルール。

---

## 6. 外部ツール統合

### 6.1. libghostty の公開 API 状況

- 公開 API は C ヘッダ (`ghostty.h`)。Zig 内部の上に薄く C API が生えている
- API は安定化「途上」で、ghostty commit SHA を固定する運用が必要
- Ghostling が最小サンプル、cmux が実戦用途
- 参照: https://github.com/ghostty-org/ghostty, https://github.com/ghostty-org/ghostling

### 6.2. cmux の Claude Code 状態検出メカニズム

**文脈**: cmux のカンバンで「Needs input」バッジが出る仕組み。

**学び**: 3 層構造:

1. **`Resources/bin/claude` ラッパー** (PATH の先頭に入れる)
   - `CMUX_SURFACE_ID` env がセットされてれば cmux 内判定
   - `--settings` で hooks JSON を注入して real claude を exec

2. **注入する hooks JSON**
   - `SessionStart` / `Stop` / `SessionEnd` / `UserPromptSubmit` / `PreToolUse` / `Notification`
   - 各 hook は `cmux claude-hook <event>` CLI を spawn

3. **Swift app 側は Unix socket の listener で `kanbario claude-hook` からのイベントを受信**
   - `Stop` → `sessions.activity = needsInput`
   - `UserPromptSubmit` → `needsInput` クリア、`running` 復帰
   - `SessionEnd` → `tasks.status = review`

### 6.3. worktrunk の `wt switch` に `--json` がない問題

**文脈**: spec 初版で `wt switch --json` を想定していたが、実際は非対応。

**学び**: 「きっとあるだろう」で書いた仕様は必ず実機で確認する。5 分のチェックで何時間もの後戻り工数を防げる。代替: `wt switch -c <branch> --no-cd` 実行後、`wt list --format=json` でパスを引く 2 段階方式。

### 6.4. cmux 内で動いている時に claude を呼ぶと cmux の shim を通る

**文脈**: bootstrap.sh の事前チェックで PATH の先頭が `/Applications/cmux.app/Contents/Resources/bin/` だと判明。

**学び**: 同じ問題が kanbario でも起きる → **kanbario の shim は自分の bundle 以外の PATH を探索し、かつ cmux.app 内の claude は skip する** ロジックが必要。

### 6.5. Sessylph の libghostty ビルドは Claude Code に投げて OK

Zenn 記事「libghostty + Claude Code terminal」の著者: 「公式ドキュメント不足でも Claude Code にお願いしたらサクッと」。**libghostty のような不安定 API はドキュメントより LLM 補助の方が早い** という現代の実践知。

---

## 7. テスト戦略

### 7.1. テストで状態機械を固めた価値

**文脈**: ユーザーが `canTransition` を 2 回修正したが、11 個のテストが仕様の真実として残る。

**学び**: 今後 `canTransition` を「ちょっといじろう」と思った時、テストが保険になる。**「過去の自分の意図」を忘れる前にコード化できた** という意味で、このタイプの milestone は実装より重要な成果。

### 7.2. テストが「仕様の書き起こし」として機能する瞬間

**文脈**: `AppStateTests` で `moveTaskUnknownID` と `persistenceEmptyStart` という負のケースを検証。

**学び**: **負のケース (nil / 空 / 不在)** を test で明示すると、将来のリファクタで挙動を変えた瞬間にテストが落ちて教えてくれる。テストが仕様書を兼ねる状態になる。

### 7.3. 統合テストで実バイナリと通信する価値

**文脈**: WorktreeServiceIntegrationTests で実際の `wt` バイナリと通信。

**学び**: モックで置き換えずに real integration を走らせると、**「環境が想定どおりか」「API が変わってないか」** が定期的に検証される。

**副作用**: 外部依存が必要 (CI で wt install が必要) / 失敗時の診断が複雑。

### 7.4. Xcode の test sandbox 問題

**文脈**: `WorktreeServiceIntegrationTests` が最初全部失敗したが、スクリプト単独では動いた。

**学び**: Xcode 新規 macOS App テンプレートは `ENABLE_APP_SANDBOX = YES` がデフォルトで、**テストも同じ sandbox で動く**。外部 process spawn が silent に失敗する。kanbario は sandbox off が必要。

### 7.5. スクリプトによる事前検証の価値

`scripts/verify-pty.swift` や `scripts/verify-worktree.swift` のような小さな Swift スクリプトで、Xcode に取り込む前にコア仕様を検証できる。Xcode の test harness より iteration が速い。

### 7.6. 「見えないバグの方が怖い」

**文脈**: `canTransition` の `||` vs `&&` バグ。

**学び**: `&&` の書き間違いは「遷移が全部拒否される」という **目に見える** バグ (drag しても動かない)。一方 `||` の書き間違いは「全部通る」という **目に見えない** バグ = テストでしか発見できない。state machine のようなルール判定は単体テストで固めるのが定石。

---

## 8. Git / 開発ワークフロー

### 8.1. 「設計 → 実装」を別コミットにする価値

**文脈**: `chore: bootstrap` (spec + scripts) を先に、`feat(milestone-A)` (実装) を後に。

**学び**: 仕様書とスクリプトが先にあり、後から実装が積まれた形が履歴で見える。将来「なぜこの設計?」と遡った時、**`git blame` が spec.md の元になったコミットを指せる** ので、実装詳細と設計判断の対応関係が追跡しやすい。

**一般原則**: 長期プロジェクトでは、**コミットが小さな ADR (Architecture Decision Record) として機能**する。

### 8.2. `.gitignore` を最初のコミットに含める意味

`.gitignore` がない状態で `git add` すると、後で ignore したいファイル (.DS_Store, xcuserdata 等) を誤って追加するリスクがある。**`.gitignore` は実装に先立つ「約束事」** として最初に入れる、が現代の git 運用のベストプラクティス。

### 8.3. ".gitignore の vendor/libghostty/ 判断"

libghostty バイナリは数十 MB になり得るので、git に入れるとリポジトリが重くなる。代わりに `scripts/fetch-libghostty.sh` で commit SHA 固定取得する方針。**「バイナリ成果物は再現可能なスクリプトで取得、git は人間が書いたものだけ」** はモノレポの健全性を保つ原則。

### 8.4. 「スコープが見える」こと自体が進捗

個人開発で挫折する最大要因は「まだどれくらいある?」の不安。残タスクの粒度と順序を文書化できている時点で、完遂確率が大きく上がる。

### 8.5. 「できた! → 嬉しい!」を連続で積むのが個人開発のコツ

**文脈**: B-4 (永続化) を B-5 (詳細画面) より後ろに置いた判断。

**学び**: 永続化は **書いた瞬間は動作が変わらない** (メモリ上の状態が DB に落ちて、次回起動時に読み込まれるだけ)。UI が動いていない段階で永続化だけ先に作ると、モチベーションの feedback loop が弱くなる。

### 8.6. 「claude 呼ばなくても使える Kanban」という挫折保険

Milestone B の時点で kanbario は **完成した Kanban アプリとして動いている**。C (Claude 統合) に進めるのは **挫折保険として極めて強い**。いつ開発が止まってもここまでのコードは自分で使える。

---

## 9. Learn by Doing で直面した落とし穴

### 9.1. `&&` と `||` の逆の失敗モード

`canTransition` 実装時のバグ。`&&` で「両方満たす」を意図したが `||` で書いてしまい、**全遷移が許可される sh** 状態に。

**教訓**: state machine / 許可判定のロジックは単体テストで固める。

### 9.2. default case `return true` のアンチパターン

許可リスト型の検証関数では「**明示されていないものは拒否**」がデフォルトであるべき。逆 (明示されていないものは許可) はセキュリティ系の設計と同じ危険性を持つ。

### 9.3. `switch (self, next)` 形式への誘惑

state machine を `if` 連鎖で書いてもよいが、将来 case を追加した時に **コンパイラが exhaustive チェックしてくれる `switch`** の方が安全。

```swift
switch (self, next) {
case (.planning, .inProgress): return true
case (.inProgress, .review):   return true
case (.review, .done):         return true
case (.review, .inProgress):   return true
default:                       return false
}
```

### 9.4. 値型の配列内 mutation が sliently 動かない罠 (再掲)

`var task = tasks[idx]; task.status = X` はコンパイル通るが動かない。`tasks[idx].status = X` で index 経由代入。

### 9.5. Swift の `Task` 予約語シャドウ

ドメインに `Task` を入れると Swift concurrency の `Task` と衝突。**ドメインオブジェクトに `Task` と名付けない** を rule に。

### 9.6. Continuous fallback paths

FileHandle を通した PTY 出力の読み取りで、error の時の扱い、EOF の扱いを分ける必要がある。短絡しない網羅的 `if/else` にする。

---

## Appendix: 順序判断のメタノート

この開発を通じて、以下の一般パターンを体験的に確認した:

- **読む → 書く**: cmux / Vibe Kanban / Ghostling を読んでから書き始めた判断は正解だった。特に cmux の hook 機構が「ラッパー + hook JSON + Unix socket」という構造を丸ごと教えてくれた
- **不確実性が低いものから**: Rust < Swift < libghostty < Claude hook の順で確実性が高い → 逆順で着手するとリスクが最後に集中するので、**確実なものから片付けて libghostty を最後にする** 戦略は意図的な選択
- **観測可能な milestone**: 各 milestone が「動くもの」を生むように切った (A: bash が起動、B: Kanban UI で使える、C: claude が spawn、D: 色がつく)。どこで止まっても残るのは "ユーザーとして使えるアプリ"

---

_この document は kanbario 開発過程で Claude Code と対話しながら抽出した学びの集合。時系列ではなく topical に再配置してある。新しい insight が出たら追加、古くなった判断は「背景」として残す。_
