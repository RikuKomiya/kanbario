import AppKit
import Foundation

// MARK: - Drag & drop into the running terminal — drop type registry
//
// AppKit に登録する drop 受信タイプの一覧だけをここに集約する。
// `NSDraggingDestination` の override メソッド本体は `GhosttyTerminalView.swift`
// の `GhosttyNSView` クラス本体側に置いている (extension で `@objc` 互換
// メソッドを override すると一部のコンパイル経路で drop dispatch が届かない
// 事象を観測したため、クラス本体配置で確実化している)。

extension GhosttyNSView {
    /// drop 受信対象タイプ。
    /// - 直接画像 (Screenshot.app からのサムネ D&D は `.tiff` / `.png`)
    /// - 画像 / 任意ファイル URL (`.fileURL`)
    /// - 純粋 URL / 文字列 (ブラウザ等からの drag)
    /// - `NSImage` が認識できる image UTType も網羅 (HEIC / WebP / GIF など)
    static let dropTypes: Set<NSPasteboard.PasteboardType> = {
        var set: Set<NSPasteboard.PasteboardType> = [
            .string,
            .URL,
            .fileURL,
            .tiff,
            .png,
            NSPasteboard.PasteboardType("public.image"),
            NSPasteboard.PasteboardType("public.url"),
            NSPasteboard.PasteboardType("public.file-url"),
        ]
        for raw in NSImage.imageTypes {
            set.insert(NSPasteboard.PasteboardType(raw))
        }
        return set
    }()
}
