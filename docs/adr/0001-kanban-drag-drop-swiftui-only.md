# ADR 0001: Kanban ドラッグ&ドロップは SwiftUI で完結する

- **Status**: Accepted
- **Date**: 2026-04-19
- **Deciders**: 本人 (solo)
- **Scope**: `Kanbario/KanbanBoardView.swift` の drag & drop UX
- **Supersedes**: なし
- **Superseded by**: なし

---

## Context

MVP のカンバンボードではカードを列間で drag して state 遷移させる UX が中心機能。SwiftUI 標準の `.onDrag` / `.draggable` で実装を始めたが、drop 時の視覚挙動で 1 週間以上 (6 連続コミット) 磨き込みを続け、ある段階で「SwiftUI の API だけでは根治できない問題」に到達した。本 ADR はそこで下した **「SwiftUI で完結させる」** 決定を残す。

### 観測された問題

1. **drop 時の preview 残像**: drop 成功時、macOS は drag preview を drop 地点で一拍静止 → フェードアウトさせる。6 コミット分の CPU と神経を使ってもゼロにできなかった。
2. **preview closure の反応性が効かない**: `.onDrag(_:preview:)` の `preview:` は drag 開始時に **NSImage として一度だけ snapshot** され、`@Observable` を binding しても再描画されない (log で実証済み)。
3. **EmptyView preview は crash**: 残像ゼロを狙って preview を `EmptyView` にすると AppKit が NSImage を作る時にクラッシュする。
4. **1x1 Color.clear preview は drag 中も不可視**: クラッシュは回避できるが「何を掴んでいるか」が完全に分からなくなる。

### 根本原因

この残像は `NSDraggingSession.animatesToDestination = true` の macOS 標準挙動。SwiftUI の `.onDrag` / `.draggable` / `.dropDestination` / `DropDelegate` のいずれも、この property に触る API を露出していない。**SwiftUI 範囲内で完全解は原理的に存在しない。**

完全解を得るには `NSViewRepresentable` で `NSDraggingSession` を自前開始し `animatesToDestination = false` を指定する必要がある (~100+ 行、NSHostingView 経由の event 中継と click/drag の責務分離が必要)。

---

## Decision

**SwiftUI 範囲に留まり、macOS 標準の drop アニメは受け入れる**。NSViewRepresentable による AppKit 直叩きには降りない。

代償として発生する「drop 時の preview 残像」は、**SwiftUI 側で強い視覚シグナルを重ね**てユーザの視線を逸らす戦略で緩和する:

| レイヤ | 実装 | 役割 |
|---|---|---|
| `.onDrag { ... }` (preview 省略) | OS default の view snapshot を preview に | drag 中の cursor 追従 |
| source card `opacity(0)` | `@Observable` binding (`draggingTaskID`) | 「何を掴んでいるか」を source 位置で示す |
| `DropPlaceholderCard` (ゴースト) | target 列末尾に dashed-border の半透明カード | **drop 先の明示 (主シグナル)** |
| `DropDelegate` + `DropProposal(.move/.forbidden)` | cursor の `+` / `⊘` マーク | drop 可否を cursor 形状で |
| column stroke highlight | `isTargeted` に連動したストローク色 | 現 drop target 列を面で示す |
| CGEventSource polling (30ms) | `.left` button state 監視 | 列外 release 時の state cleanup |

この組み合わせで **drop 完了時の視線は SwiftUI 管理下のゴースト消滅 + 新列へのカード instant 出現に誘導**される。AppKit の残像は視覚的に周辺情報に格下げされる。

---

## Alternatives Considered

### A. `NSViewRepresentable` + 自前 `NSDraggingSession`
- ✅ `animatesToDestination = false` で残像完全抑止
- ✅ drag 中も visible preview 両立
- ❌ `NSHostingView` は subclass 不可 (drag source method が non-open)
- ❌ 代替実装 (NSPanGestureRecognizer or 子 hosting view + container NSView) は click と drag の責務分離でハマりやすい
- ❌ 工数 1〜2 時間、MVP の他マイルストーン (libghostty / Claude hook 統合) への影響が大きい
- **判定**: 投資効果が疑わしい。将来 Phase 2 以降で UX が事業価値になる時点で再検討。

### B. `.onDrag` with `preview: { EmptyView() }`
- ✅ 残像ゼロ (snapshot が空なのでフェードするものが無い)
- ❌ **クラッシュ再現** (2026-04-19 時点)
- **判定**: 使えない。

### C. `.onDrag` with `preview: { Color.clear.frame(width: 1, height: 1) }`
- ✅ crash 回避
- ✅ 残像ほぼゼロ
- ❌ drag 中に cursor 追従する visual が無く、「何を掴んでるか」情報が完全に欠落
- **判定**: drag 中の視認性を犠牲にしすぎ。

### D. `.onDrag(_:preview:)` で `opacity` binding を使い drop 時に消す
- ❌ **原理的に不可能**。preview は drag 開始時に NSImage として焼き付き、以降 SwiftUI の再描画はドラッグビジュアルに届かない (log で実証)。
- **判定**: 発想自体が誤り。

### E. `.draggable(_:preview:)` (newer API) への移行
- ❌ 下層は同じ `NSDraggingSession`。`animatesToDestination` にアクセスできないのは同じ。
- **判定**: 移行する積極理由なし。

---

## Consequences

### Positive
- 全てのロジックが Swift + SwiftUI で完結。言語統一方針 (spec §1.1) を崩さない。
- コード量が最小。`KanbanBoardView.swift` は ~230 行で完結。
- SwiftUI の native animation (`.transition`, `.animation`) を全面活用でき、drop 前後の挙動調整が宣言的。
- 競合 `langwatch/kanban-code` と同系統のアプローチ。OSS 事例が生きた参考になる。

### Negative
- drop 成功時に AppKit の preview フェード (〜0.3s) が視覚的に残る。**完全な無音 drop は実現されていない**。
- 将来 "UX の完璧さ" を売り物にするタイミングで再投資が必要になる (= D. `NSViewRepresentable` へ降りる)。

### Neutral
- 残像緩和のために `DropPlaceholderCard` / `DropDelegate` / `CGEventSource polling` / `@Observable draggingTaskID` など **SwiftUI 側に資産が蓄積**された。将来 NSView 化する場合でも、drop 先の可視化レイヤ (ゴースト・ハイライト) はそのまま再利用できる。

---

## Reference

### 関連コミット
- `d619a81` ~ `d4c6180` — source opacity / polling / transition=.identity / EmptyView preview の試行錯誤
- 本 ADR 確定時の refactor — `preview:` 省略 + ゴーストカード + `DropDelegate` 移行

### 外部参照
- [langwatch/kanban-code — DragAndDrop.swift](https://github.com/langwatch/kanban-code/blob/main/Sources/KanbanCode/DragAndDrop.swift) — 同ドメイン競合の参考実装
- [Drag & Drop with SwiftUI — SwiftUI Lab](https://swiftui-lab.com/drag-drop-with-swiftui/) — macOS preview の既知バグ言及
- [onmyway133/blog#951](https://github.com/onmyway133/blog/issues/951) — NSViewRepresentable による drag source 自前実装例 (将来 Alternative A を実装する時のテンプレ)

### 再検討のトリガ
以下の状況になった時、本 ADR の decision を見直す:
1. ユーザフィードバックで「drop 時の残像が使用感を損なう」と複数回指摘された
2. Apple が `NSDraggingSession.animatesToDestination` 相当の SwiftUI API を公開した (macOS 27+ で要調査)
3. kanbario が MVP を超えて **UX の磨き込みが事業価値** になるフェーズに入った
