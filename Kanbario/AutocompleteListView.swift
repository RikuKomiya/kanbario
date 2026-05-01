import SwiftUI
import AppKit

// MARK: - AutocompleteListView

/// PromptEditor の上に被せる popup リスト。選択 index の item がハイライト、
/// 他はグレー表示。↑↓ keyDown はテキストエディタ側に intercept されていて、
/// ここでは selectedIndex prop を読んで描画するだけ。
struct AutocompleteListView<Item: AutocompleteItem>: View {
    let items: [Item]
    let selectedIndex: Int
    var onTap: (Item) -> Void

    /// popup の最大高さ。候補が多すぎて画面を覆うのを防ぐ。超えた分は内部
    /// スクロール。1 行 ~35pt として 7-8 件見える計算。
    private let maxHeight: CGFloat = 260

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        row(item: item, isSelected: idx == selectedIndex)
                            .id(item.id)  // scroll target
                            .contentShape(Rectangle())
                            .onTapGesture { onTap(item) }
                    }
                }
            }
            // ↑↓ で選択が popup 内の可視域外に動いた時、自動でその行を中央に
            // スクロールする。Claude Code / IDE の標準挙動と揃える。
            .onChange(of: selectedIndex) { _, new in
                guard new >= 0, new < items.count else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(items[new].id, anchor: .center)
                }
            }
        }
        .frame(minWidth: 260, maxWidth: 420, maxHeight: maxHeight, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(WF.paper)
                .shadow(color: Color.black.opacity(0.22), radius: 10, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(WF.line, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func row(item: Item, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.displayName)
                .font(WFFont.mono(12))
                .fontWeight(isSelected ? .bold : .regular)
                .foregroundStyle(isSelected ? WF.paper : WF.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail = item.detail {
                Text(detail)
                    .font(WFFont.mono(10))
                    .foregroundStyle(isSelected ? WF.paper.opacity(0.85) : WF.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? WF.accent : Color.clear
        )
    }
}

// MARK: - PromptEditorWithAutocomplete

/// PromptEditor + 候補 popup を ZStack 統合した高レベル view。
///
/// 使い方: NewTaskSheet 側で `$bodyText` をバインドし、`files` / `slashes`
/// を流し込む。@ / / 入力時に popup が現れ、↑↓ で選択、Enter で挿入。
/// Esc で popup 閉じる。click でも挿入可能。
///
/// **設計上の trick:**
/// - 候補の絞り込み (fuzzy match + top N) は親 view から受けた fullList から
///   自前でやる (TriggerContext.query を使う)。これで親はキャッシュ済み候補を
///   一度渡せば良い、絞り込みのたびに取り直す必要が無い。
/// - popup の y 座標は cursor rect.maxY + ちょっと下。行の高さだけ下げれば
///   「カーソルの真下」感が出る。
/// - popup が editor の下端を突き抜けるような狭い editor では位置が微妙に
///   なるが、MVP では editor の minHeight を 120 以上にしておけば実用上問題なし。
struct PromptEditorWithAutocomplete: View {
    @Binding var text: String
    /// `@` で検索する候補 (file list)。親が worktree 切替などで更新する。
    let files: [FileEntry]
    /// `/` で検索する候補 (skills + commands)。
    let slashes: [SlashEntry]
    /// Markdown toolbar など、親 view から native text operation を実行したい時に渡す。
    var handle: PromptEditorHandle? = nil
    var minHeight: CGFloat = 120
    var emptyTabInsertion: String? = nil
    var droppedItemFormatter: (([PromptDroppedItem]) -> PromptTextInsertion?)? = nil

    /// trigger 状態 (PromptEditor が通知する)。popup の表示判定に使う。
    @State private var trigger: TriggerContext? = nil
    /// cursor rect (editor 内 local 座標)。popup の offset に使う。
    @State private var cursorRect: CGRect = .zero
    /// popup 内の選択 index。trigger 出現 / query 変化でリセット。
    @State private var selectedIndex: Int = 0
    /// NSTextView を直接操作するための handle。@ commit 時に SwiftUI Binding
    /// 経由の全文 replace を避けて、IME marked text / cursor 位置を壊さない。
    @State private var localEditorHandle = PromptEditorHandle()

    private var activeEditorHandle: PromptEditorHandle {
        handle ?? localEditorHandle
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            PromptEditor(
                text: $text,
                onTriggerChange: { ctx, rect in
                    if ctx != trigger { selectedIndex = 0 }
                    trigger = ctx
                    cursorRect = rect
                },
                onNavigationKey: handleNavigationKey(_:),
                handle: activeEditorHandle,
                droppedItemFormatter: droppedItemFormatter,
                emptyTabInsertion: emptyTabInsertion,
                minHeight: minHeight
            )
            .frame(minHeight: minHeight)

            if let trigger, !currentFilteredItems(for: trigger).isEmpty {
                popupOverlay(trigger: trigger)
                    .offset(x: cursorRect.minX,
                            y: cursorRect.maxY + 4)
            }
        }
    }

    // MARK: - Popup overlay (AnyView で file/slash を同じ枠で扱う)

    @ViewBuilder
    private func popupOverlay(trigger: TriggerContext) -> some View {
        switch trigger.trigger {
        case .file:
            let items = filteredFiles(query: trigger.query)
            AutocompleteListView(
                items: items,
                selectedIndex: min(selectedIndex, max(0, items.count - 1)),
                onTap: { commit(item: $0) }
            )
        case .slash:
            let items = filteredSlashes(query: trigger.query)
            AutocompleteListView(
                items: items,
                selectedIndex: min(selectedIndex, max(0, items.count - 1)),
                onTap: { commit(item: $0) }
            )
        }
    }

    // MARK: - Filtering

    private func filteredFiles(query: String) -> [FileEntry] {
        score(items: files, query: query)
    }

    private func filteredSlashes(query: String) -> [SlashEntry] {
        score(items: slashes, query: query)
    }

    private func score<T: AutocompleteItem>(items: [T], query: String) -> [T] {
        items
            .map { (item: $0, score: fuzzyScore(item: $0, query: query)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(15)
            .map { $0.item }
    }

    /// popup 表示中の「現在の filtered 候補数」を取得するためのユーティリティ。
    /// navigation key ハンドラが wrap-around する時に count を知る必要がある。
    private func currentFilteredItems(for trigger: TriggerContext) -> [any AutocompleteItem] {
        switch trigger.trigger {
        case .file:  return filteredFiles(query: trigger.query)
        case .slash: return filteredSlashes(query: trigger.query)
        }
    }

    // MARK: - Navigation key handling

    /// PromptEditor から「矢印 / Enter / Esc を押された」通知を受け取り、
    /// popup が表示中なら選択操作に変換して true を返す。表示してない時は
    /// false で textview の通常動作に任せる。
    private func handleNavigationKey(_ key: NavigationKey) -> Bool {
        guard let trigger else { return false }
        let items = currentFilteredItems(for: trigger)
        if items.isEmpty { return false }

        switch key {
        case .up:
            selectedIndex = (selectedIndex - 1 + items.count) % items.count
            return true
        case .down:
            selectedIndex = (selectedIndex + 1) % items.count
            return true
        case .enter:
            // 選択 index に対応する item を取り出して commit
            let clampedIdx = min(selectedIndex, items.count - 1)
            commitAnyItem(items[clampedIdx])
            return true
        case .escape:
            self.trigger = nil
            return true
        }
    }

    // MARK: - Commit (text replacement)

    private func commit<T: AutocompleteItem>(item: T) {
        applyCommit(insertionText: item.insertionText)
    }

    private func commitAnyItem(_ item: any AutocompleteItem) {
        applyCommit(insertionText: item.insertionText)
    }

    /// 現在の trigger.range を insertionText で置換する。
    ///
    /// **設計ポイント:** SwiftUI Binding (`text = newText`) 経由で全文 replace
    /// すると、updateNSView が NSTextView の全文を replaceCharacters で
    /// 差し替える動作になり、IME marked text / selectedRange / input context
    /// が壊れる (日本語入力が乱れる症状の直接原因)。そのため handle.replaceRange
    /// で **NSTextView 側に直接 range 置換** を依頼する。結果は textDidChange
    /// 経由で SwiftUI Binding に流れるので、state 同期も自然に維持される。
    private func applyCommit(insertionText: String) {
        guard let trigger else { return }
        let ns = text as NSString
        let safeRange = NSRange(
            location: min(trigger.range.location, ns.length),
            length: min(trigger.range.length, ns.length - min(trigger.range.location, ns.length))
        )
        // 挿入後に space を付けて「次の語」に自然に移れるようにする。
        let replacement = insertionText + " "
        activeEditorHandle.replaceRange(safeRange, with: replacement)
        self.trigger = nil
        self.selectedIndex = 0
    }
}
