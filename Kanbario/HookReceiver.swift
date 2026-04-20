import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// CLI/main.swift が socket に流す 1 行 JSON のスキーマ (受信側)。
/// `payload` は claude が hook 起動時に stdin で渡す生 JSON 文字列。
/// 必要な event だけが 2nd-pass で `Data(payload.utf8)` を再 decode する想定。
struct HookMessage: Decodable, Sendable {
    let event: String
    let surfaceID: String
    let sessionID: String
    let payload: String
}

/// Unix domain socket で claude-hook CLI からのメッセージを受け取り、
/// AppState の handler に MainActor へホップさせて配るレシーバ。
///
/// - listener fd は POSIX で持つ (CLI 側と対称、Network.framework の
///   unix サポートは macOS 26 でも分かりにくいので低レベルに統一)。
/// - accept は専用 Thread で行い、各接続ごとに同 thread 内で全 byte を
///   readEnd まで吸って 1 メッセージ単位で decode する (CLI が 1 接続 =
///   1 メッセージ + close する仕様なので multiplex 不要)。
/// - 失敗は黙って無視 (decode error / 切断) — hook は best-effort、
///   1 イベント取りこぼしても UI は致命的に壊れない。
nonisolated final class HookReceiver {

    enum StartError: Error, CustomStringConvertible {
        case socketCreate(errno: Int32)
        case bind(errno: Int32, path: String)
        case listen(errno: Int32)
        case pathTooLong(length: Int, max: Int)

        var description: String {
            switch self {
            case .socketCreate(let e):
                return "socket() failed: errno=\(e)"
            case .bind(let e, let path):
                return "bind(\(path)) failed: errno=\(e)"
            case .listen(let e):
                return "listen() failed: errno=\(e)"
            case .pathTooLong(let len, let max):
                return "socket path too long (\(len) > \(max))"
            }
        }
    }

    let socketPath: String
    private let dispatch: @Sendable (HookMessage) -> Void

    private let fdLock = NSLock()
    private var listenerFD: Int32 = -1
    private var acceptThread: Thread?

    init(socketPath: String, dispatch: @escaping @Sendable (HookMessage) -> Void) {
        self.socketPath = socketPath
        self.dispatch = dispatch
    }

    deinit { stop() }

    func start() throws {
        // 親ディレクトリの保証 + 古いソケットファイルの削除。
        // bind は同一パスに対して EADDRINUSE を返すので、前回プロセスの
        // クラッシュ残骸があれば握りつぶして再 bind する。
        let parent = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(atPath: socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socketCreate(errno: errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxLen else {
            close(fd)
            throw StartError.pathTooLong(length: pathBytes.count, max: maxLen)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let buf = raw.bindMemory(to: CChar.self)
            for (i, b) in pathBytes.enumerated() { buf[i] = CChar(bitPattern: b) }
            buf[pathBytes.count] = 0
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let e = errno
            close(fd)
            throw StartError.bind(errno: e, path: socketPath)
        }
        guard listen(fd, 16) == 0 else {
            let e = errno
            close(fd)
            throw StartError.listen(errno: e)
        }

        fdLock.lock()
        listenerFD = fd
        fdLock.unlock()

        let thread = Thread { [weak self] in
            self?.acceptLoop(fd: fd)
        }
        thread.name = "kanbario.hook.accept"
        thread.start()
        acceptThread = thread
    }

    func stop() {
        fdLock.lock()
        let fd = listenerFD
        listenerFD = -1
        fdLock.unlock()
        if fd >= 0 { close(fd) }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - Background thread

    private func acceptLoop(fd: Int32) {
        while true {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let cfd = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(fd, sa, &clientLen)
                }
            }
            if cfd < 0 {
                let e = errno
                if e == EBADF || e == EINVAL { return }   // listener closed
                if e == EINTR { continue }
                continue
            }
            handleClient(fd: cfd)
        }
    }

    private func handleClient(fd: Int32) {
        defer { close(fd) }

        // CLI は 1 接続あたり 1 行 JSON + close する。EOF まで読む。
        // 64KB を超えるペイロードは届かない想定 (claude の hook stdin は
        // 通常数百バイト〜数 KB)。安全弁として上限を切って捨てる。
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let cap = 64 * 1024
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk.prefix(n))
            if buffer.count > cap { return }
        }
        while let last = buffer.last, last == 0x0A {
            buffer.removeLast()
        }
        guard !buffer.isEmpty else { return }
        guard let message = try? JSONDecoder().decode(HookMessage.self, from: buffer) else {
            return
        }
        dispatch(message)
    }
}
