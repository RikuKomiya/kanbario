import SwiftUI
import AppKit

/// kanbario prompt 入力用の SwiftUI-compatible text editor。
/// 内部で `NSTextView` を `NSViewRepresentable` で wrap し、SwiftUI TextEditor
/// では取れない以下を外に公開する:
///
/// - **cursor offset** (UTF-16 単位、selectedRange.location)
/// - **cursor 画面 rect** (editor 内 local 座標 / window 座標に変換可能)
/// - **keyDown intercept** (↑↓Enter Esc を autocomplete 側に奪うためのフック)
///
/// Wireframe の paperAlt / Noteworthy 風スタイルは表面的な styling で揃えて、
/// ダークモード / rounded corner / padding は外側の container に任せる。
/// autocomplete 側から NSTextView を直接操作するための handle。
///
/// **目的:** @/slash commit 時の text 書き換えを SwiftUI Binding 経由ではなく
/// NSTextView native API (`replaceCharacters`) で行う。Binding 経由で全文 replace
/// すると:
/// - `hasMarkedText()` (IME composing buffer) が破棄される → 日本語入力が不安定
/// - `selectedRange` が (0,0) にリセットされ cursor が文頭へ戻る
/// - IME input context が失われる
/// という副作用があるので、commit のような小さな range 置換は native 経路を使う。
struct PromptTextInsertion {
    let text: String
    let appendix: String?

    init(text: String, appendix: String? = nil) {
        self.text = text
        self.appendix = appendix
    }
}

enum PromptDroppedItem {
    case file(URL)
    case url(URL)
    case text(String)
}

final class PromptEditorHandle {
    fileprivate weak var textView: NSTextView?

    /// 指定 range を string で置き換え、cursor を置換文字列の末尾に移す。
    /// undo stack にも入る (shouldChangeText を経由するため)。
    func replaceRange(
        _ range: NSRange,
        with string: String,
        selectedRangeAfter: NSRange? = nil
    ) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let location = min(max(range.location, 0), ns.length)
        let length = min(max(range.length, 0), ns.length - location)
        let safeRange = NSRange(location: location, length: length)
        guard tv.shouldChangeText(in: safeRange, replacementString: string) else { return }
        tv.window?.makeFirstResponder(tv)
        tv.replaceCharacters(in: safeRange, with: string)
        tv.didChangeText()
        let newCursor = safeRange.location + (string as NSString).length
        let rawNextRange = selectedRangeAfter ?? NSRange(location: newCursor, length: 0)
        let updatedLength = (tv.string as NSString).length
        let nextLocation = min(max(rawNextRange.location, 0), updatedLength)
        let nextLength = min(max(rawNextRange.length, 0), updatedLength - nextLocation)
        let safeNextRange = NSRange(location: nextLocation, length: nextLength)
        tv.setSelectedRange(safeNextRange)
        tv.scrollRangeToVisible(safeNextRange)
    }

    func insertText(_ string: String) {
        insert(PromptTextInsertion(text: string))
    }

    func insert(_ insertion: PromptTextInsertion) {
        guard let tv = textView else { return }
        Self.insert(insertion, into: tv, at: tv.selectedRange())
    }

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    func wrapSelection(prefix: String, suffix: String, placeholder: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let selected = selectedText(in: tv)
        let content = selected.isEmpty ? placeholder : selected
        let replacement = "\(prefix)\(content)\(suffix)"
        let prefixLength = (prefix as NSString).length
        let selection = NSRange(
            location: range.location + prefixLength,
            length: (content as NSString).length
        )
        replaceRange(range, with: replacement, selectedRangeAfter: selection)
    }

    func prefixSelectedLines(with prefix: String, placeholder: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            let replacement = "\(prefix)\(placeholder)"
            let selection = NSRange(
                location: range.location + (prefix as NSString).length,
                length: (placeholder as NSString).length
            )
            replaceRange(range, with: replacement, selectedRangeAfter: selection)
            return
        }

        let ns = tv.string as NSString
        let paragraphRange = ns.paragraphRange(for: range)
        let chunk = ns.substring(with: paragraphRange)
        let lines = chunk.components(separatedBy: "\n")
        let hasTrailingNewline = chunk.hasSuffix("\n")
        let prefixed = lines.enumerated().map { index, line in
            if index == lines.count - 1, line.isEmpty, hasTrailingNewline {
                return ""
            }
            return line.isEmpty ? prefix.trimmingCharacters(in: .whitespaces) : "\(prefix)\(line)"
        }.joined(separator: "\n")
        replaceRange(
            paragraphRange,
            with: prefixed,
            selectedRangeAfter: NSRange(location: paragraphRange.location, length: (prefixed as NSString).length)
        )
    }

    func insertCodeBlock(language: String = "", placeholder: String = "code") {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let selected = selectedText(in: tv)
        let content = selected.isEmpty ? placeholder : selected
        let replacement = "```\(language)\n\(content)\n```"
        let selection = selected.isEmpty
            ? NSRange(location: range.location + 4 + (language as NSString).length, length: (content as NSString).length)
            : NSRange(location: range.location + (replacement as NSString).length, length: 0)
        replaceRange(range, with: replacement, selectedRangeAfter: selection)
    }

    func insertMarkdownLink(
        title: String? = nil,
        destination: String,
        selectDestination: Bool = false
    ) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let selected = selectedText(in: tv)
        let label = {
            if let title, !title.isEmpty { return title }
            return selected.isEmpty ? "link text" : selected
        }()
        let replacement = "[\(label)](\(destination))"
        let selection: NSRange
        if selectDestination {
            selection = NSRange(
                location: range.location + ("[\(label)](" as NSString).length,
                length: (destination as NSString).length
            )
        } else if selected.isEmpty {
            selection = NSRange(location: range.location + 1, length: (label as NSString).length)
        } else {
            selection = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        }
        replaceRange(range, with: replacement, selectedRangeAfter: selection)
    }

    func insertMarkdownImage(
        alt: String = "image",
        source: String,
        selectSource: Bool = false
    ) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let selected = selectedText(in: tv)
        let altText = selected.isEmpty ? alt : selected
        let replacement = "![\(altText)](\(source))"
        let selection = selectSource
            ? NSRange(location: range.location + ("![\(altText)](" as NSString).length,
                      length: (source as NSString).length)
            : NSRange(location: range.location + (replacement as NSString).length, length: 0)
        replaceRange(range, with: replacement, selectedRangeAfter: selection)
    }

    private func selectedText(in tv: NSTextView) -> String {
        let ns = tv.string as NSString
        let range = tv.selectedRange()
        guard range.location >= 0,
              range.location <= ns.length,
              range.location + range.length <= ns.length else { return "" }
        return ns.substring(with: range)
    }

    fileprivate static func insert(
        _ insertion: PromptTextInsertion,
        into tv: NSTextView,
        at range: NSRange
    ) {
        let ns = tv.string as NSString
        let location = min(max(range.location, 0), ns.length)
        let length = min(max(range.length, 0), ns.length - location)
        let safeRange = NSRange(location: location, length: length)

        guard tv.shouldChangeText(in: safeRange, replacementString: insertion.text) else { return }
        tv.window?.makeFirstResponder(tv)
        tv.undoManager?.beginUndoGrouping()
        tv.replaceCharacters(in: safeRange, with: insertion.text)
        tv.didChangeText()

        let inlineEnd = safeRange.location + (insertion.text as NSString).length
        let desiredSelection = NSRange(location: inlineEnd, length: 0)

        if let appendix = insertion.appendix, !appendix.isEmpty {
            let current = tv.string
            let separator: String
            if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                separator = ""
            } else if current.hasSuffix("\n\n") {
                separator = ""
            } else if current.hasSuffix("\n") {
                separator = "\n"
            } else {
                separator = "\n\n"
            }
            let appendixText = separator + appendix
            let updatedLength = (tv.string as NSString).length
            let endRange = NSRange(location: updatedLength, length: 0)
            if tv.shouldChangeText(in: endRange, replacementString: appendixText) {
                tv.replaceCharacters(in: endRange, with: appendixText)
                tv.didChangeText()
            }
        }

        tv.undoManager?.endUndoGrouping()
        tv.setSelectedRange(desiredSelection)
        tv.scrollRangeToVisible(desiredSelection)
    }
}

struct PromptEditor: NSViewRepresentable {
    @Binding var text: String

    /// trigger コンテキストが変わったときに呼ばれる。nil なら autocomplete 非表示。
    var onTriggerChange: (TriggerContext?, CGRect) -> Void

    /// ↑ / ↓ / Enter / Esc を autocomplete 側で処理したい時に呼ぶ。
    /// - 戻り値が true なら editor 側には伝播させない (= 選択キーを食う)
    /// - false なら textview の通常動作を継続
    var onNavigationKey: (NavigationKey) -> Bool

    /// 外部から NSTextView を直接触りたい場合の handle。nil なら素の editor として動作。
    var handle: PromptEditorHandle? = nil
    /// drag/drop や paste された URL / file を Markdown 挿入に変換する。
    var droppedItemFormatter: (([PromptDroppedItem]) -> PromptTextInsertion?)? = nil
    /// 空の editor で Tab を押した時に挿入する starter template。
    var emptyTabInsertion: String? = nil

    var minHeight: CGFloat = 120

    enum NavigationKey {
        case up, down, enter, escape
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = AutocompleteTextView()
        textView.delegate = context.coordinator
        textView.autocompleteHandler = context.coordinator
        textView.droppedItemFormatter = droppedItemFormatter
        textView.emptyTabInsertion = emptyTabInsertion
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsDocumentBackgroundColorChange = false

        // SwiftUI の TextEditor と同じ「水平には広がる / 垂直は必要に応じて」挙動。
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        // handle が渡っていれば textView の参照を覚えさせる (weak 保持)。
        handle?.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // SwiftUI View struct が再構築されるたびに Coordinator 内の
        // parent 参照を最新に差し替える。この 1 行が無いと
        // onNavigationKey / onTriggerChange などの closure が init 時の
        // snapshot のまま固まり、↑↓Enter が popup 側で intercept されず
        // NSTextView の通常動作 (改行 / カーソル移動) にフォールバックしてしまう。
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? AutocompleteTextView else { return }
        // handle が new SwiftUI snapshot で別インスタンスになった場合の保険。
        handle?.textView = tv
        tv.droppedItemFormatter = droppedItemFormatter
        tv.emptyTabInsertion = emptyTabInsertion
        // **IME composing 中は text 同期を skip**: hasMarkedText() = true の時
        // replaceCharacters すると marked text buffer が壊れて日本語入力が乱れる。
        // IME 確定後 (marked text が空になる) に textDidChange 経由で改めて同期される。
        if tv.hasMarkedText() { return }
        if tv.string != text {
            // 外側から text が書き換えられた場合 (state restore 等)。
            // 通常の @/slash commit は handle.replaceRange を経由するので、
            // このブロックは滅多に走らない (起動時の初期 text 注入など)。
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            if tv.shouldChangeText(in: full, replacementString: text) {
                tv.replaceCharacters(in: full, with: text)
                tv.didChangeText()
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate, AutocompleteKeyHandling {
        /// SwiftUI View 再構築のたびに updateNSView が書き換える。let ではなく
        /// var にしておかないと、新しい closure (@State の最新 snapshot を
        /// 含む) が反映されない (NSViewRepresentable の定番トラップ)。
        var parent: PromptEditor

        init(parent: PromptEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            notifyTrigger(tv: tv)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            notifyTrigger(tv: tv)
        }

        /// text / selection が動いたときに trigger 状態を計算して親に通知する。
        private func notifyTrigger(tv: NSTextView) {
            let cursor = tv.selectedRange().location
            let ctx = detectTrigger(text: tv.string, cursorOffset: cursor)
            let rect = cursorRectInEditorLocalSpace(tv: tv, at: cursor)
            parent.onTriggerChange(ctx, rect)
        }

        /// cursor 位置の矩形を editor (scroll view) 内 local 座標で返す。
        /// SwiftUI ZStack で `.offset(x:y:)` に使うのに適した座標系。
        private func cursorRectInEditorLocalSpace(
            tv: NSTextView, at offset: Int
        ) -> CGRect {
            guard let layoutManager = tv.layoutManager,
                  let container = tv.textContainer else { return .zero }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: offset, length: 0),
                actualCharacterRange: nil
            )
            let rect = layoutManager.boundingRect(
                forGlyphRange: glyphRange, in: container
            )
            return rect.offsetBy(
                dx: tv.textContainerOrigin.x,
                dy: tv.textContainerOrigin.y
            )
        }

        // MARK: - AutocompleteKeyHandling

        func handle(navigationKey: NavigationKey) -> Bool {
            parent.onNavigationKey(navigationKey)
        }
    }
}

// MARK: - AutocompleteKeyHandling

/// NSTextView のサブクラスから coordinator に「矢印/Enter/Esc が押された」を
/// 通知するための protocol。NSViewRepresentable の衝突を避けるため
/// NavigationKey 型は PromptEditor の nested enum を typealias。
typealias NavigationKey = PromptEditor.NavigationKey

protocol AutocompleteKeyHandling: AnyObject {
    /// 戻り値が true なら textview 本来の挙動を中断する。
    func handle(navigationKey: NavigationKey) -> Bool
}

// MARK: - AutocompleteTextView

/// keyDown を intercept して autocomplete 側に選択キーを奪わせる NSTextView。
final class AutocompleteTextView: NSTextView {
    weak var autocompleteHandler: AutocompleteKeyHandling?
    var droppedItemFormatter: (([PromptDroppedItem]) -> PromptTextInsertion?)?
    var emptyTabInsertion: String?

    override func keyDown(with event: NSEvent) {
        if let handler = autocompleteHandler {
            // keyCode は macOS 共通の仮想キー code。↑=126, ↓=125,
            // Enter/Return=36, NumpadEnter=76, Esc=53。
            let navKey: NavigationKey? = {
                switch event.keyCode {
                case 126: return .up
                case 125: return .down
                case 36, 76: return .enter
                case 53:  return .escape
                default:  return nil
                }
            }()
            if let navKey, handler.handle(navigationKey: navKey) {
                return  // autocomplete が食った = textview には流さない
            }
        }
        if event.keyCode == 48,
           let emptyTabInsertion,
           string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fullRange = NSRange(location: 0, length: (string as NSString).length)
            PromptEditorHandle.insert(
                PromptTextInsertion(text: emptyTabInsertion),
                into: self,
                at: fullRange
            )
            return
        }
        super.keyDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canFormatDroppedItems(from: sender.draggingPasteboard)
            ? .copy
            : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canFormatDroppedItems(from: sender.draggingPasteboard)
            ? .copy
            : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let insertion = formattedInsertion(from: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        PromptEditorHandle.insert(
            insertion,
            into: self,
            at: NSRange(location: index, length: 0)
        )
        return true
    }

    override func paste(_ sender: Any?) {
        if let insertion = formattedInsertion(from: NSPasteboard.general) {
            PromptEditorHandle.insert(insertion, into: self, at: selectedRange())
            return
        }
        super.paste(sender)
    }

    private func canFormatDroppedItems(from pasteboard: NSPasteboard) -> Bool {
        formattedInsertion(from: pasteboard) != nil
    }

    private func formattedInsertion(from pasteboard: NSPasteboard) -> PromptTextInsertion? {
        guard let formatter = droppedItemFormatter else { return nil }
        let items = Self.promptDroppedItems(from: pasteboard)
        guard !items.isEmpty else { return nil }
        return formatter(items)
    }

    private static func promptDroppedItems(from pasteboard: NSPasteboard) -> [PromptDroppedItem] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty {
            return urls.map { $0.isFileURL ? .file($0) : .url($0) }
        }

        if let raw = pasteboard.string(forType: .URL),
           let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme != nil {
            return [url.isFileURL ? .file(url) : .url(url)]
        }

        if let raw = pasteboard.string(forType: .string),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [.text(raw)]
        }

        return []
    }
}
