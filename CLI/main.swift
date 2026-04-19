import Foundation
#if canImport(Darwin)
import Darwin
#endif

// kanbario claude-hook CLI
//
// Resources/bin/claude shim から `kanbario claude-hook <event>` で呼ばれる。
// stdin の JSON ペイロードと環境変数を 1 行 JSON にまとめ、
// KANBARIO_SOCKET_PATH の Unix socket に流すだけの薄い relay。
// 状態遷移ロジックは app 側 (HookReceiver / AppState) に集約する。
//
// 失敗しても claude を巻き込まないため exit code は常に 0。
// (cmux 流: hook の失敗で agent を止めない)

private let knownEvents: Set<String> = [
    "session-start",
    "stop",
    "session-end",
    "prompt-submit",
    "pre-tool-use",
    "notification",
]

private struct HookMessage: Encodable {
    let event: String
    let surfaceID: String
    let sessionID: String
    let payload: String
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

private func run() -> Int32 {
    let args = CommandLine.arguments
    guard args.count >= 3, args[1] == "claude-hook" else {
        FileHandle.standardError.write(Data("usage: kanbario claude-hook <event>\n".utf8))
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
    let sessionID = env["KANBARIO_SESSION_ID"] ?? ""

    // shim は KANBARIO_SURFACE_ID 未設定で pass-through するので通常は到達しないが、
    // 環境誤設定や手動起動時のサイレント no-op 経路として保持。
    guard !socketPath.isEmpty else { return 0 }

    let stdinBytes = FileHandle.standardInput.readDataToEndOfFile()
    let payloadString = String(data: stdinBytes, encoding: .utf8) ?? ""
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
