import Foundation
#if canImport(Darwin)
import Darwin
#endif

// kanbario agent hook CLI
//
// Resources/bin/{claude,codex} shim から
// `kanbario <agent>-hook <event>` で呼ばれる。
// stdin の JSON ペイロードと環境変数を 1 行 JSON にまとめ、
// KANBARIO_SOCKET_PATH の Unix socket に流すだけの薄い relay。
// 状態遷移ロジックは app 側 (HookReceiver / AppState) に集約する。
//
// 失敗しても agent を巻き込まないため exit code は常に 0。
// (cmux 流: hook の失敗で agent を止めない)

private let knownEvents: Set<String> = [
    "session-start",
    "stop",
    "session-end",
    "prompt-submit",
    "pre-tool-use",
    "post-tool-use",
    "permission-request",
    "notification",
]

private struct HookMessage: Encodable {
    let event: String
    let surfaceID: String
    let sessionID: String
    let payload: String
}

private func extractSessionID(from payload: String) -> String {
    guard let data = payload.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return "" }
    return (json["session_id"] as? String)
        ?? (json["sessionId"] as? String)
        ?? ""
}

@discardableResult
private func sendOneLine(_ data: Data, to path: String, timeout: TimeInterval = 3.0) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
    guard pathBytes.count <= maxLen else { return false }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        let buf = raw.bindMemory(to: CChar.self)
        for (i, b) in pathBytes.enumerated() {
            buf[i] = CChar(bitPattern: b)
        }
        buf[pathBytes.count] = 0
    }

    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    let tvSize = socklen_t(MemoryLayout<timeval>.size)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, tvSize)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tvSize)

    let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else { return false }

    var framed = data
    framed.append(0x0A)
    let written = framed.withUnsafeBytes { raw -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return write(fd, base, framed.count)
    }
    return written == framed.count
}

/// codex の `notify=[...]` config から起動された場合のエントリ。
/// codex は `argv = [program, ...fixed-args, <json-payload>]` の形で起動するので
/// `args[2]` が JSON 文字列。`type` field を内部 event 名にマップして UDS に流す。
///
/// 0.130.0 で観測している type:
///   - "agent-turn-complete" → "stop" (kanbario の inProgress → review 遷移トリガー)
/// 将来 codex が他 type (e.g. permission/notification) を増やしたら ここで追加 mapping。
private func debugLog(_ line: String) {
    // デバッグ用 (2026-05-09): codex-notify 経路が実際に呼ばれているか可視化。
    // 動作確認後に削除可。
    let now = ISO8601DateFormatter().string(from: Date())
    let payload = "[\(now)] codex-notify: \(line)\n"
    if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/kanbario-codex-debug.log")) {
        fh.seekToEndOfFile()
        fh.write(Data(payload.utf8))
        try? fh.close()
    } else {
        FileManager.default.createFile(
            atPath: "/tmp/kanbario-codex-debug.log",
            contents: Data(payload.utf8)
        )
    }
}

private func runCodexNotify(jsonArg: String) -> Int32 {
    let env = ProcessInfo.processInfo.environment
    let socketPath = env["KANBARIO_SOCKET_PATH"] ?? ""
    let surfaceID = env["KANBARIO_SURFACE_ID"] ?? ""

    debugLog("entered argLen=\(jsonArg.count) surface=\(surfaceID.isEmpty ? "<empty>" : surfaceID) socket=\(socketPath.isEmpty ? "<empty>" : socketPath)")

    guard !socketPath.isEmpty, !surfaceID.isEmpty else {
        debugLog("bail: socket/surface env missing")
        return 0
    }

    guard let data = jsonArg.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        debugLog("bail: cannot parse JSON arg, raw=\(jsonArg.prefix(200))")
        return 0
    }

    let codexType = (json["type"] as? String) ?? ""
    let mappedEvent: String
    switch codexType {
    case "agent-turn-complete":
        mappedEvent = "stop"
    default:
        debugLog("bail: unrecognized codex type=\(codexType)")
        return 0
    }

    let sessionID = (json["thread-id"] as? String)
        ?? (env["KANBARIO_SESSION_ID"] ?? "")

    let message = HookMessage(
        event: mappedEvent,
        surfaceID: surfaceID,
        sessionID: sessionID,
        payload: jsonArg
    )
    guard let encoded = try? JSONEncoder().encode(message) else {
        debugLog("bail: HookMessage encode failed")
        return 0
    }
    let ok = sendOneLine(encoded, to: socketPath)
    debugLog("relayed type=\(codexType) → event=\(mappedEvent) sock=\(ok ? "OK" : "FAIL") session=\(sessionID)")
    return 0
}

private func run() -> Int32 {
    let args = CommandLine.arguments

    // codex `notify` 経路: argv[1]="codex-notify", argv[2]=<json>。
    // hook 系と違い stdin ではなく argv で payload が来る。
    if args.count >= 3, args[1] == "codex-notify" {
        return runCodexNotify(jsonArg: args[2])
    }

    guard args.count >= 3,
          args[1] == "claude-hook" || args[1] == "codex-hook" else {
        FileHandle.standardError.write(Data("usage: kanbario <claude-hook|codex-hook|codex-notify> <event|json>\n".utf8))
        return 2
    }

    let event = args[2]
    guard knownEvents.contains(event) else {
        FileHandle.standardError.write(Data("unknown event: \(event)\n".utf8))
        return 2
    }

    let env = ProcessInfo.processInfo.environment
    let socketPath = env["KANBARIO_SOCKET_PATH"] ?? ""
    let surfaceID = env["KANBARIO_SURFACE_ID"] ?? ""
    let stdinBytes = FileHandle.standardInput.readDataToEndOfFile()
    let payloadString = String(data: stdinBytes, encoding: .utf8) ?? ""
    let sessionID = {
        let fromEnv = env["KANBARIO_SESSION_ID"] ?? ""
        return fromEnv.isEmpty ? extractSessionID(from: payloadString) : fromEnv
    }()

    // shim は KANBARIO_SURFACE_ID 未設定で pass-through するので通常は到達しないが、
    // 環境誤設定や手動起動時のサイレント no-op 経路として保持。
    guard !socketPath.isEmpty else { return 0 }

    let message = HookMessage(
        event: event,
        surfaceID: surfaceID,
        sessionID: sessionID,
        payload: payloadString
    )

    guard let encoded = try? JSONEncoder().encode(message) else { return 0 }
    _ = sendOneLine(encoded, to: socketPath)
    return 0
}

exit(run())
