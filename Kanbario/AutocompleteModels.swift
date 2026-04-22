import Foundation

// MARK: - AutocompleteItem

/// prompt editor で `@` / `/` 入力時に popup に出す候補の共通型。
/// 現状は FileEntry と SlashEntry の 2 種類だが、同一 protocol で扱うことで
/// AutocompleteListView 側の表示ロジックを共通化する。
protocol AutocompleteItem: Identifiable, Hashable {
    /// 候補リストに出す 1 行の主タイトル (例: "login.swift" / "/review")
    var displayName: String { get }
    /// 2 行目に細字で出す補助文 (例: path / description)。
    var detail: String? { get }
    /// 選択時に prompt に差し込まれる文字列。先頭の `@` / `/` を含む形で保持する
    /// (triggerContext の startIndex からこの文字列で置換するため)。
    var insertionText: String { get }
    /// マッチ用のスコアリング対象テキスト (displayName + detail を空白で連結)。
    /// fuzzy 検索の対象にする。
    var searchableText: String { get }
}

// MARK: - FileEntry

/// `@` trigger の候補。git ls-files から取った 1 ファイル。
struct FileEntry: AutocompleteItem {
    let id: String
    let relativePath: String

    init(relativePath: String) {
        self.id = relativePath
        self.relativePath = relativePath
    }

    var displayName: String {
        (relativePath as NSString).lastPathComponent
    }
    var detail: String? {
        let dir = (relativePath as NSString).deletingLastPathComponent
        return dir.isEmpty ? nil : dir
    }
    var insertionText: String { "@" + relativePath }
    var searchableText: String { relativePath }
}

// MARK: - SlashEntry

/// `/` trigger の候補。Claude Code の slash command / user command / skill / agent。
struct SlashEntry: AutocompleteItem {
    enum Kind: String, Hashable {
        case command   // /init, /review etc
        case skill     // ~/.claude/skills/*.md の frontmatter
        case agent     // ~/.claude/agents/*.md
    }
    enum Source: String, Hashable {
        case builtin   // Claude Code 内蔵 (kanbario 側で静的に持つ)
        case user      // ~/.claude/**/*.md
        case project   // <repo>/.claude/**/*.md (優先)
    }

    let id: String
    let name: String           // "review" (先頭 / は含まない)
    let description: String?   // frontmatter の description / 概要
    let kind: Kind
    let source: Source

    var displayName: String { "/" + name }
    var detail: String? {
        let sourceLabel = "[\(kind.rawValue) · \(source.rawValue)]"
        if let description, !description.isEmpty {
            return "\(sourceLabel) \(description)"
        }
        return sourceLabel
    }
    var insertionText: String { "/" + name }
    var searchableText: String {
        [name, description ?? ""].joined(separator: " ")
    }
}

// MARK: - TriggerContext

/// テキスト内で trigger (`@` / `/`) が見つかった位置 + 入力中 query を保持する。
/// PromptEditor が textDidChange で毎回再計算して SwiftUI 側に通知する。
///
/// startOffset / endOffset は `text.utf16.count` ベースの NSRange 相当の位置
/// (NSTextView の selectedRange と直接やり取りするため、UTF-16 unit で統一)。
struct TriggerContext: Equatable {
    enum Trigger: Character { case file = "@", slash = "/" }

    let trigger: Trigger
    let query: String
    /// 置換範囲 (trigger 文字を含む開始位置〜 cursor 位置) を NSRange で表現。
    let range: NSRange
}

// MARK: - Trigger extraction (ccpocket の _extractTriggerQuery Swift port)

/// ccpocket の _extractTriggerQuery 相当。
/// text と cursor offset (UTF-16 単位) から、直前の trigger 位置を探して
/// TriggerContext を返す。
///
/// 検出条件:
/// - cursor より前に trigger 文字がある
/// - trigger の前が行頭 or 区切り文字 (whitespace / ( / [ / { / : / , / ;)
/// - trigger から cursor までに whitespace が含まれない (= query の途中)
///
/// これで email の `@` や URL path の `/` を誤検知しない。
func extractTriggerQuery(
    text: String,
    cursorOffset: Int,
    trigger: TriggerContext.Trigger
) -> TriggerContext? {
    let utf16 = text.utf16
    guard cursorOffset >= 0, cursorOffset <= utf16.count else { return nil }

    // cursor 位置までの subsequence を対象にして、そこで trigger 文字を探す。
    let endIdx = utf16.index(utf16.startIndex, offsetBy: cursorOffset)
    guard let beforeStr = String(utf16[utf16.startIndex..<endIdx]) else { return nil }

    // trigger 文字の最後の出現位置を utf16 offset で探す
    let triggerChar = trigger.rawValue
    var triggerOffset = -1
    for (offset, ch) in beforeStr.utf16.enumerated() {
        if let scalar = Unicode.Scalar(ch),
           Character(scalar) == triggerChar {
            triggerOffset = offset
        }
    }
    guard triggerOffset >= 0 else { return nil }

    // trigger の 1 文字前をチェック
    if triggerOffset > 0 {
        let prevUnit = beforeStr.utf16[
            beforeStr.utf16.index(beforeStr.utf16.startIndex, offsetBy: triggerOffset - 1)
        ]
        if let scalar = Unicode.Scalar(prevUnit) {
            let prevChar = Character(scalar)
            let allowed: Set<Character> = [
                " ", "\t", "\n", "\r", "(", "[", "{", ":", ",", ";"
            ]
            if !allowed.contains(prevChar) { return nil }
        }
    }

    // trigger の後ろから cursor までを query として取り出す。
    // 途中に whitespace が入っていたら、ユーザーはトリガ入力を抜けていると
    // みなして nil (これが無いと "foo @bar baz|" で baz もクエリに混ざる)。
    let queryStartOffset = triggerOffset + 1
    let queryLength = cursorOffset - queryStartOffset
    guard queryLength >= 0 else { return nil }

    let qStart = beforeStr.utf16.index(beforeStr.utf16.startIndex, offsetBy: queryStartOffset)
    let qEnd = beforeStr.utf16.index(beforeStr.utf16.startIndex, offsetBy: cursorOffset)
    guard let query = String(beforeStr.utf16[qStart..<qEnd]) else { return nil }
    if query.contains(where: { $0.isWhitespace }) { return nil }

    return TriggerContext(
        trigger: trigger,
        query: query,
        range: NSRange(location: triggerOffset, length: cursorOffset - triggerOffset)
    )
}

/// `@` と `/` の両 trigger を試して、見つかった方を返す。両方ヒットしたら
/// cursor により近い (= offset が大きい) 方を優先。
func detectTrigger(text: String, cursorOffset: Int) -> TriggerContext? {
    let atCtx = extractTriggerQuery(text: text, cursorOffset: cursorOffset, trigger: .file)
    let slashCtx = extractTriggerQuery(text: text, cursorOffset: cursorOffset, trigger: .slash)
    switch (atCtx, slashCtx) {
    case (nil, nil): return nil
    case (let a?, nil): return a
    case (nil, let s?): return s
    case (let a?, let s?):
        return a.range.location >= s.range.location ? a : s
    }
}

// MARK: - Fuzzy scoring

/// 極めて軽量な fuzzy match スコア。完全一致 > 先頭一致 > 部分一致 > 文字順序一致。
/// query が空なら最大スコア (= すべて表示)。0 を返したら候補外。
func fuzzyScore(item: any AutocompleteItem, query: String) -> Int {
    let target = item.searchableText.lowercased()
    let q = query.lowercased()
    if q.isEmpty { return 1_000 }
    if target == q { return 10_000 }
    if target.hasPrefix(q) { return 5_000 }
    if target.contains(q) {
        // 出現位置が前方ほど高得点
        if let range = target.range(of: q) {
            let distance = target.distance(from: target.startIndex, to: range.lowerBound)
            return max(1, 3_000 - distance)
        }
    }
    // 文字順序が合えば最低限の得点 (fuzzy subsequence match)
    var tIdx = target.startIndex
    for qch in q {
        guard let found = target[tIdx...].firstIndex(of: qch) else { return 0 }
        tIdx = target.index(after: found)
    }
    return 100
}
