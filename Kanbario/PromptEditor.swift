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
final class PromptEditorHandle {
    fileprivate weak var textView: NSTextView?

    /// 指定 range を string で置き換え、cursor を置換文字列の末尾に移す。
    /// undo stack にも入る (shouldChangeText を経由するため)。
    func replaceRange(_ range: NSRange, with string: String) {
        guard let tv = textView else { return }
        guard tv.shouldChangeText(in: range, replacementString: string) else { return }
        tv.replaceCharacters(in: range, with: string)
        tv.didChangeText()
        let newCursor = range.location + (string as NSString).length
        tv.setSelectedRange(NSRange(location: newCursor, length: 0))
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
        super.keyDown(with: event)
    }
}
