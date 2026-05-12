import AppKit
import Foundation
import UniformTypeIdentifiers

/// kanbario の clipboard / drag-drop 経路を集約する helper。
///
/// 設計思想:
/// - ghostty の `read_clipboard_cb` と `write_clipboard_cb` は「文字列だけ」を
///   やり取りする C ABI。画像を直接渡すレーンが無い。
/// - claude / codex CLI の画像認識は **shell-escape された画像ファイルパスを
///   PTY 経由で text として受け取れば** 成立する (CLI 側がその path を読んで
///   `[Image #N]` プレースホルダ表示する)。
/// - したがって「pasteboard に画像しか無い」場合は temp file に書き出して
///   path を返すだけで text-only callback の制約を突破できる。
///
/// 対応 source:
/// - file URL drop / paste (画像でない普通のファイルもパスとして渡す)
/// - plain text (Telegram Desktop など Qt 系の Mac OS Roman fallback 対策)
/// - 画像 raw data (PNG / TIFF / その他 image-conform UTType)
/// - URL 文字列 (https://... のような bare URL)
enum GhosttyPasteboardHelper {

    // MARK: - Pasteboard wiring

    /// ghostty が selection clipboard 用に使う専用 pasteboard。
    /// 名前は upstream ghostty と同じ識別子で揃える (互換のため)。
    private static let selectionPasteboard = NSPasteboard(
        name: NSPasteboard.Name("com.mitchellh.ghostty.selection")
    )

    static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD: return .general
        case GHOSTTY_CLIPBOARD_SELECTION: return selectionPasteboard
        default: return nil
        }
    }

    // MARK: - Top-level resolution

    /// `ghostty_runtime_read_clipboard_cb` の中身として呼ぶ。
    /// 戻り値は `ghostty_surface_complete_clipboard_request` にそのまま渡す前提
    /// (= bracketed paste で child PTY に流れる shell-ready text)。
    static func resolveForPaste(_ pb: NSPasteboard) -> String {
        if let joined = realFileURLJoined(in: pb) {
            return joined
        }
        if let text = plainText(in: pb) {
            return text
        }
        if let imagePath = saveClipboardImageAsTempPath(pb) {
            return imagePath
        }
        if let raw = pb.string(forType: .URL), !raw.isEmpty {
            return escapeForShell(raw)
        }
        return ""
    }

    /// 走行中ターミナルへの D&D 経路。drop された pasteboard を text に変換する。
    ///
    /// 順序の意図:
    /// 1. **画像 raw data → kanbario の temp file** を最優先。NSFilePromise drag
    ///    (Photos / Safari / メールアプリ等) は `public.file-url` の placeholder
    ///    として `/var/folders/.../T/TemporaryItems/(A Document Being Saved By
    ///    <app>)/foo.png` のような **括弧 + 空白を含む path** を提供する。
    ///    `escapeForShell` で `\(` `\ ` `\)` に変換すると、claude / codex CLI の
    ///    path parser (shell ではなく独自実装) はこの backslash 表記を解釈できず
    ///    画像認識に失敗する。pasteboard には同時に `public.png` も載っている
    ///    のでそこから直接生 bytes を読み、kanbario 配下の ASCII-only な
    ///    `kanbario-clipboard-*.png` に書き出した path を渡す方が確実。
    /// 2. **実在する file URL**。Finder からの通常 drag (画像 raw data 非同梱)
    ///    はここで拾う。pasteboard には `public.file-url` のみで実 file。
    /// 3. URL 文字列 / plain text の text fallback。
    static func resolveForDrop(_ pb: NSPasteboard) -> String {
        if let imagePath = saveClipboardImageAsTempPath(pb) {
            return imagePath
        }
        if let joined = realFileURLJoined(in: pb) {
            return joined
        }
        if let raw = pb.string(forType: .URL), !raw.isEmpty {
            return escapeForShell(raw)
        }
        if let text = plainText(in: pb), !text.isEmpty {
            return text
        }
        return ""
    }

    /// `ghostty_runtime_write_clipboard_cb` の text 用。画像書き出しは現状無し
    /// (ghostty 自身が image を pasteboard に書く経路が今のところ無いため)。
    static func writeString(_ value: String, to location: ghostty_clipboard_e) {
        guard let pb = pasteboard(for: location) else { return }
        pb.clearContents()
        pb.setString(value, forType: .string)
    }

    /// 将来 `surface_has_clipboard` 等を実装する時のための contents 検出。
    /// 現状の kanbario callback では未使用だが、helper 完備のため公開しておく。
    static func hasContent(in location: ghostty_clipboard_e) -> Bool {
        guard let pb = pasteboard(for: location) else { return false }
        let types = pb.types ?? []
        return types.contains(.fileURL)
            || types.contains(.string)
            || types.contains(.URL)
            || hasImageData(in: pb)
    }

    // MARK: - File URLs

    /// pasteboard 上の URL 群から「実在するファイル」だけを抽出して shell-escape
    /// 後にスペース連結する。NSFilePromise drag は実体が無い placeholder URL を
    /// advertise するので `FileManager.fileExists` で除外する。
    /// 非ファイル URL (https://...) は実在チェックの代わりに absoluteString を返す。
    private static func realFileURLJoined(in pb: NSPasteboard) -> String? {
        guard let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
              !urls.isEmpty else { return nil }
        let parts: [String] = urls.compactMap { url in
            if url.isFileURL {
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return escapeForShell(url.path)
            }
            return url.absoluteString.isEmpty ? nil : escapeForShell(url.absoluteString)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    // MARK: - Plain text

    /// utf-8 plain text の preferred type。一部の Qt 系アプリ (Telegram Desktop
    /// など) が `com.apple.traditional-mac-plain-text` (Mac OS Roman) を utf-8
    /// より前に登録するため、そのまま `.string` を引くと非 ASCII が `?` に
    /// 落ちる。utf-8 を先に問い合わせて回避する。
    private static let utf8PlainTextType =
        NSPasteboard.PasteboardType("public.utf8-plain-text")

    private static func plainText(in pb: NSPasteboard) -> String? {
        let types = pb.types ?? []
        for preferred in [utf8PlainTextType, NSPasteboard.PasteboardType.string] {
            if types.contains(preferred),
               let value = pb.string(forType: preferred),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    // MARK: - Image extraction → temp file

    private static let tempImagePrefix = "kanbario-clipboard-"
    /// 10 MB を超える画像は CLI に流すと bracketed paste が現実的でない長さに
    /// なるので reject。閾値はまず保守的に。
    private static let maxImageBytes = 10 * 1024 * 1024

    private static let temporaryImageOwnershipLock = NSLock()
    private static var ownedTemporaryImagePaths: Set<String> = []

    private static func hasImageData(in pb: NSPasteboard) -> Bool {
        let types = pb.types ?? []
        if types.contains(.png) || types.contains(.tiff) { return true }
        return types.contains { type in
            UTType(type.rawValue)?.conforms(to: .image) ?? false
        }
    }

    private static func saveClipboardImageAsTempPath(_ pb: NSPasteboard) -> String? {
        guard let (data, ext) = imagePayload(in: pb) else { return nil }
        guard data.count <= maxImageBytes else {
            NSLog("kanbario.image: rejected (\(data.count) bytes > \(maxImageBytes))")
            return nil
        }
        let url = makeTempImageURL(extension: ext)
        do {
            try data.write(to: url)
        } catch {
            NSLog("kanbario.image: temp write failed: \(error.localizedDescription)")
            return nil
        }
        registerOwnedTempImage(url)
        NSLog("kanbario.image: wrote temp file \(url.lastPathComponent) (\(data.count) bytes)")
        return escapeForShell(url.path)
    }

    /// 優先順:
    /// 1. 直接 `.png` data → そのまま PNG (lossless で CLI が一番確実に読む)
    /// 2. UTType が image-conform な custom type → そのまま生 data + 推奨拡張子
    /// 3. NSImage 経由で TIFF → PNG 化 (Screenshot.app などはこの経路に落ちる)
    private static func imagePayload(in pb: NSPasteboard) -> (Data, String)? {
        if let png = pb.data(forType: .png) {
            return (png, "png")
        }
        for type in pb.types ?? [] {
            guard type != .png, type != .tiff,
                  let utType = UTType(type.rawValue),
                  utType.conforms(to: .image),
                  let data = pb.data(forType: type),
                  let ext = utType.preferredFilenameExtension else { continue }
            return (data, ext)
        }
        if hasImageData(in: pb),
           let img = NSImage(pasteboard: pb),
           let tiff = img.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            return (png, "png")
        }
        return nil
    }

    private static func makeTempImageURL(extension ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        let suffix = String(UUID().uuidString.prefix(8))
        let filename = "\(tempImagePrefix)\(stamp)-\(suffix).\(ext)"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)
    }

    private static func registerOwnedTempImage(_ url: URL) {
        let path = url.standardizedFileURL.path
        temporaryImageOwnershipLock.lock()
        ownedTemporaryImagePaths.insert(path)
        temporaryImageOwnershipLock.unlock()
    }

    /// kanbario が temp dir に書き出した画像のうち、引数で指定された path
    /// だけを削除する。`fileURLs(...)` などで CLI に渡したあと、CLI 側が
    /// 読み終わったタイミングで呼ぶことを想定。所有していない path は触らない
    /// (= ユーザーが自分で置いたファイルを誤削除しない安全側設計)。
    static func cleanupOwnedTempImages(_ urls: [URL]) {
        for url in urls {
            let path = url.standardizedFileURL.path
            temporaryImageOwnershipLock.lock()
            let owned = ownedTemporaryImagePaths.remove(path) != nil
            temporaryImageOwnershipLock.unlock()
            guard owned else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Shell escape

    /// shell が単語境界として扱う文字 + glob / 引用符。改行を含むケースは
    /// 単一引用符で囲む方が安全なので別経路 (escapeForShell)。
    private static let shellSpecialChars = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    /// POSIX shell-escape。改行を含むなら single-quote でくるみ、それ以外は
    /// 個別文字を backslash escape する。`/var/folders/.../My Picture.png`
    /// のような空白を含む temp path が CLI に 1 引数として届くようにする。
    static func escapeForShell(_ value: String) -> String {
        if value.contains(where: { $0 == "\n" || $0 == "\r" }) {
            let q = value.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(q)'"
        }
        var result = value
        for ch in shellSpecialChars {
            result = result.replacingOccurrences(of: String(ch), with: "\\\(ch)")
        }
        return result
    }
}
