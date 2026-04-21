import Foundation

/// Claude Code の transcript JSONL ファイルを tail し、新しい会話エントリを
/// callback で通知する。
///
/// **ファイル:** `~/.claude/projects/<encoded-project-path>/<session-uuid>.jsonl`
/// - encoded-project-path は `/Users/foo/path` → `-Users-foo-path` (slash と
///   dot の両方を hyphen に変換) という Claude Code の内部 encode 規則に従う
/// - 各行は Claude Code が新規メッセージを確定するたびに追記される
///   (type: user / assistant / system)
///
/// **重要な制約:**
/// - ファイルは SessionStart の数百 ms 後に作られる → 短いリトライで open
/// - 書き込み中に不完全行 (末尾 `\n` なし) が一時的に存在しうる → lineBuffer
///   で持ち越し、`\n` が来てから JSON decode する
/// - fileHandle の close 漏れは fd leak につながるので source cancel handler
///   で確実に閉じる
final class TranscriptTailer {

    /// カードの live log に載せる 1 エントリ。Claude の transcript 行をいくつ
    /// かの代表型に正規化したもの (raw JSON は保持しない)。
    struct LogEntry: Hashable {
        enum Kind: String, Codable { case user, assistant, tool, system }
        let kind: Kind
        let text: String
        let timestamp: Date
    }

    private let transcriptURL: URL
    private let onEvent: @Sendable (LogEntry?, Data) -> Void
    private let queue = DispatchQueue(label: "kanbario.transcript.tail", qos: .utility)

    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var lineBuffer = Data()
    private var stopped = false

    /// 各行を 1 回ずつ callback で通知する。
    /// - `entry`: UI 用に正規化した LogEntry (text / tool 等の先頭 1 件のみ)。
    ///   抽出対象外の行 (system 等) では nil になる。
    /// - `rawLine`: JSONL 1 行の生バイト。Swift 6 strict concurrency で
    ///   `[String: Any]` を closure 引数にすると Sendable 違反になるため、
    ///   parse 結果ではなく bytes を渡す。呼び出し側は必要に応じて
    ///   `JSONSerialization` で再 parse する (MainActor 上で実行される
    ///   想定なので dict を作っても境界を越えない)。
    init(
        transcriptURL: URL,
        onEvent: @escaping @Sendable (LogEntry?, Data) -> Void
    ) {
        self.transcriptURL = transcriptURL
        self.onEvent = onEvent
    }

    deinit {
        source?.cancel()
        try? fileHandle?.close()
    }

    /// tail を開始する。ファイルが未作成の場合は最大 5 秒 (100ms × 50 回)
    /// 待って出現を見張る。その間に stop() が呼ばれれば抜ける。
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.openWithRetry(attempts: 50, interval: 0.1)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.source?.cancel()
            self.source = nil
            try? self.fileHandle?.close()
            self.fileHandle = nil
        }
    }

    // MARK: - File open + watch

    private func openWithRetry(attempts: Int, interval: TimeInterval) {
        for _ in 0..<attempts {
            if stopped { return }
            if FileManager.default.fileExists(atPath: transcriptURL.path) {
                attachSource()
                return
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    private func attachSource() {
        guard let handle = try? FileHandle(forReadingFrom: transcriptURL) else { return }
        self.fileHandle = handle

        // 初回 open 直後に既存内容も全て読む (履歴を表示に含めるため)。
        drainAvailable()

        let fd = handle.fileDescriptor
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self, let s = self.source else { return }
            if s.data.contains(.delete) {
                self.stop()
                return
            }
            self.drainAvailable()
        }
        src.setCancelHandler { [weak self] in
            try? self?.fileHandle?.close()
            self?.fileHandle = nil
        }
        self.source = src
        src.resume()
    }

    /// fileHandle の現在位置から EOF まで読み、行単位に分割して decode。
    /// 末尾が改行で終わらない場合は lineBuffer に持ち越し、次回書き込みで
    /// 続きと結合する (Claude が書き込み中に `\n` 無しで flush することはない
    /// はずだが、安全のため)。
    private func drainAvailable() {
        guard let handle = fileHandle else { return }
        let data = handle.availableData
        if data.isEmpty { return }
        lineBuffer.append(data)

        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let lineBytes = lineBuffer.subdata(in: lineBuffer.startIndex..<nl)
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            guard !lineBytes.isEmpty else { continue }
            let entry = (try? JSONSerialization.jsonObject(with: lineBytes))
                .flatMap { $0 as? [String: Any] }
                .flatMap { Self.buildEntry(from: $0) }
            onEvent(entry, lineBytes)
        }
    }

    // MARK: - JSON parsing

    /// 1 行分の JSON dict から LogEntry を抽出する。Claude Code の transcript
    /// スキーマに厳密に追従せず、堅牢さを優先:
    /// - `type == "user"` → message.content (string か array) から最初の text
    /// - `type == "assistant"` → message.content の最初の text または tool_use
    /// - それ以外 (system 等) → nil (UI の LiveLogView には流さない)
    ///
    /// 呼び出し側が structured data を欲しい場合は TranscriptTailer の
    /// onEvent に渡ってくる raw JSON dict を直接見ること。
    static func buildEntry(from json: [String: Any]) -> LogEntry? {
        let type = (json["type"] as? String) ?? ""
        let timestampStr = json["timestamp"] as? String
        let timestamp = timestampStr.flatMap {
            ISO8601DateFormatter().date(from: $0)
        } ?? Date()

        switch type {
        case "user":
            let text = extractUserText(from: json)
            guard !text.isEmpty else { return nil }
            return LogEntry(kind: .user,
                            text: trimmed(text),
                            timestamp: timestamp)
        case "assistant":
            if let entry = extractAssistantEntry(from: json, timestamp: timestamp) {
                return entry
            }
            return nil
        default:
            return nil
        }
    }

    private static func extractUserText(from json: [String: Any]) -> String {
        guard let message = json["message"] as? [String: Any] else { return "" }
        if let s = message["content"] as? String { return s }
        if let blocks = message["content"] as? [[String: Any]] {
            for b in blocks {
                if (b["type"] as? String) == "text",
                   let t = b["text"] as? String {
                    return t
                }
            }
        }
        return ""
    }

    private static func extractAssistantEntry(
        from json: [String: Any],
        timestamp: Date
    ) -> LogEntry? {
        guard let message = json["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return nil }
        for block in blocks {
            let blockType = block["type"] as? String ?? ""
            if blockType == "text",
               let text = block["text"] as? String,
               !text.isEmpty {
                return LogEntry(kind: .assistant,
                                text: trimmed(text),
                                timestamp: timestamp)
            }
            if blockType == "tool_use",
               let name = block["name"] as? String {
                let input = block["input"] as? [String: Any] ?? [:]
                return LogEntry(kind: .tool,
                                text: "\(name)\(summarizeToolInput(input))",
                                timestamp: timestamp)
            }
        }
        return nil
    }

    /// 先頭の 1 key-value を `(key: value-trimmed)` 形式で短く。UI 行が 1 行 mono
    /// で表示できる長さに収まる想定。
    private static func summarizeToolInput(_ input: [String: Any]) -> String {
        guard let key = input.keys.sorted().first else { return "" }
        let value = input[key]
        let stringValue: String
        if let s = value as? String {
            stringValue = s
        } else if let v = value {
            stringValue = "\(v)"
        } else {
            stringValue = ""
        }
        let single = stringValue.replacingOccurrences(of: "\n", with: " ")
        let truncated = single.count > 40
            ? String(single.prefix(40)) + "…"
            : single
        return " (\(key): \(truncated))"
    }

    private static func trimmed(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(of: "\n", with: " ")
        let stripped = collapsed.trimmingCharacters(in: .whitespaces)
        if stripped.count > 120 {
            return String(stripped.prefix(120)) + "…"
        }
        return stripped
    }

    // MARK: - Path resolution

    /// Claude Code 内部 encode: `/Users/foo/my.path` → `-Users-foo-my-path`。
    /// slash と dot の両方を hyphen に変換する。
    static func encodeProjectPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    /// worktreeURL + session-id から transcript ファイル URL を組み立てる。
    static func transcriptURL(for worktreeURL: URL, sessionID: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let encoded = encodeProjectPath(worktreeURL.path)
        return home
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
            .appendingPathComponent(encoded)
            .appendingPathComponent("\(sessionID).jsonl")
    }
}
