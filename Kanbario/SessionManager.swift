import Foundation
import Darwin

/// PTY + Process を所有する actor。
///
/// Milestone A: bash / echo を spawn → 標準出力のバイト列を AsyncStream で流す。
/// 永続化 (GRDB) は Milestone B で追加予定。
actor SessionManager {

    // MARK: - Types

    struct SessionID: Hashable, Codable, CustomStringConvertible {
        let raw: UUID
        static func new() -> SessionID { SessionID(raw: UUID()) }
        var description: String { raw.uuidString }
    }

    /// 1 セッション = 1 PTY + 1 子プロセス。
    final class LiveSession {
        let id: SessionID
        let pid: Int32
        let masterFD: Int32
        /// PTY から読んだ生バイトのストリーム。購読者 1 つ前提の MVP 実装。
        let bytes: AsyncStream<Data>
        let continuation: AsyncStream<Data>.Continuation
        /// 終了イベント。EOF / exit を通知する。
        let termination: AsyncStream<Int32>
        private let terminationCont: AsyncStream<Int32>.Continuation

        init(id: SessionID, pid: Int32, masterFD: Int32) {
            self.id = id
            self.pid = pid
            self.masterFD = masterFD
            var byteCont: AsyncStream<Data>.Continuation!
            self.bytes = AsyncStream<Data> { byteCont = $0 }
            self.continuation = byteCont
            var termCont: AsyncStream<Int32>.Continuation!
            self.termination = AsyncStream<Int32> { termCont = $0 }
            self.terminationCont = termCont
        }

        func push(_ data: Data) { continuation.yield(data) }
        func finish(exitCode: Int32) {
            continuation.finish()
            terminationCont.yield(exitCode)
            terminationCont.finish()
        }
    }

    enum Error: Swift.Error {
        case spawnFailed(underlying: Swift.Error)
        case writeFailed(errno: Int32)
        case sessionNotFound
    }

    // MARK: - State

    private var sessions: [SessionID: LiveSession] = [:]
    private var processes: [SessionID: Process] = [:]

    // MARK: - API

    /// claude 本体を PTY 経由で spawn する。MVP 時点では hook 注入は行わず、
    /// プロセス exit を SessionManager.readLoop の終端で検知して UI 側の状態遷移
    /// (inProgress → review) を駆動する。
    ///
    /// - Parameters:
    ///   - task: 対応する TaskCard。初回プロンプトは task.body をそのまま渡す
    ///   - worktreeURL: wt が作った worktree のルート (claude の cwd)
    ///   - claudeExecutable: nil の場合 PATH から探す (典型: /opt/homebrew/bin/claude)
    /// - Throws: claude が見つからない場合 .spawnFailed
    func startClaude(task: TaskCard, worktreeURL: URL,
                     claudeExecutable: URL? = nil) async throws -> LiveSession {
        let executable: URL
        if let explicit = claudeExecutable {
            executable = explicit
        } else if let found = Self.locateExecutable("claude") {
            executable = found
        } else {
            throw Error.spawnFailed(
                underlying: NSError(domain: "kanbario.SessionManager", code: 127,
                                    userInfo: [NSLocalizedDescriptionKey:
                                        "claude binary not found in PATH. `brew install claude` or set explicit path."])
            )
        }

        // Commit 2 で Unix socket の path や HOOK_CLI を足す予定。いまは
        // KANBARIO_SURFACE_ID だけ仕込んでおき、将来 shim 経由になったときに
        // 「kanbario の中で動いている」判定が機能するよう布石を打っておく。
        var env = ProcessInfo.processInfo.environment
        env["KANBARIO_SURFACE_ID"] = task.id.uuidString
        env["KANBARIO_TASK_ID"] = task.id.uuidString
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        // GUI (Xcode/Finder) 起動のアプリは launchd の細い PATH を継承するため、
        // ユーザの .zshrc で足された Homebrew / node 系のパスが効かない。
        // claude 側の stop hook (node 実行) や MCP クライアントがコケるので、
        // 典型的な user-local bin を前置しておく。
        env["PATH"] = Self.augmentedPATH(current: env["PATH"])

        return try await start(
            executable: executable,
            arguments: [task.body],
            cwd: worktreeURL,
            environment: env
        )
    }

    /// 子プロセスに渡す PATH を補う。launchd 継承の貧弱な PATH の手前に
    /// user-local bin を挿す。既に同じパスがあれば重複させない。
    ///
    /// 候補は「Mac 開発機でよく登場する dev toolchain の bin 位置」:
    ///   - ~/.local/bin, ~/.volta/bin, ~/.cargo/bin, ~/.bun/bin, ~/.deno/bin
    ///   - /opt/homebrew/{bin,sbin} (Apple Silicon Homebrew)
    ///   - /usr/local/{bin,sbin} (Intel Homebrew / 手動インストール)
    ///
    /// これでも足りないユーザー (asdf / mise 等) は Settings で PATH 指定できる
    /// ようにするのが将来の拡張。MVP では hardcode で 9 割のケースを拾う。
    static func augmentedPATH(current: String?) -> String {
        let home = NSHomeDirectory()
        let additions = [
            "\(home)/.local/bin",
            "\(home)/.volta/bin",
            "\(home)/.cargo/bin",
            "\(home)/.bun/bin",
            "\(home)/.deno/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
        ]
        let existing = (current ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        var ordered: [String] = []
        for p in additions + existing where !p.isEmpty {
            if seen.insert(p).inserted { ordered.append(p) }
        }
        return ordered.joined(separator: ":")
    }

    /// PATH から実行可能ファイルを探す。Xcode ランナーの PATH は絞られているので
    /// WorktreeService と同じく Homebrew の典型パスを fallback として見に行く。
    private static func locateExecutable(_ name: String) -> URL? {
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let fallbacks = ["/opt/homebrew/bin", "/usr/local/bin",
                         "/Users/\(NSUserName())/.local/bin"]
        var seen = Set<String>()
        for dir in envPaths + fallbacks where seen.insert(dir).inserted {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// セッションの子プロセスを SIGTERM (fallback SIGKILL) で終了させる。
    /// done 時 cleanup で使う。既に死んでいる場合は no-op。
    func kill(id: SessionID) {
        guard let process = processes[id] else { return }
        if process.isRunning {
            process.terminate()
        }
    }

    /// コマンドを PTY 経由で起動する。
    func start(executable: URL, arguments: [String] = [], cwd: URL? = nil,
               environment: [String: String]? = nil,
               cols: UInt16 = 120, rows: UInt16 = 40) async throws -> LiveSession {
        let handles = try PTY.openpty(cols: cols, rows: rows)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        if let environment { process.environment = environment }

        let slaveHandle = FileHandle(fileDescriptor: handles.slave, closeOnDealloc: false)
        process.standardInput  = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError  = slaveHandle

        do {
            try process.run()
        } catch {
            close(handles.master)
            close(handles.slave)
            throw Error.spawnFailed(underlying: error)
        }

        // 親側は slave を閉じる (子だけが保持すべき)
        close(handles.slave)

        let session = LiveSession(
            id: .new(),
            pid: process.processIdentifier,
            masterFD: handles.master
        )
        sessions[session.id] = session
        processes[session.id] = process

        // PTY master から非同期で読み続ける
        let masterFD = handles.master
        let sid = session.id
        let wrappedSession = session
        let wrappedProcess = process

        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            await Self.readLoop(masterFD: masterFD, session: wrappedSession,
                                process: wrappedProcess,
                                onExit: { exitCode in
                                    await self?.sessionEnded(id: sid, exitCode: exitCode)
                                })
        }

        return session
    }

    /// セッションに入力バイトを書き込む (PTY master 経由で子プロセスの stdin に)。
    func write(to id: SessionID, bytes: Data) throws {
        guard let session = sessions[id] else { throw Error.sessionNotFound }
        let n = bytes.withUnsafeBytes { buf -> Int in
            Darwin.write(session.masterFD, buf.baseAddress, buf.count)
        }
        if n < 0 { throw Error.writeFailed(errno: errno) }
    }

    /// 全稼働セッションの ID。
    func liveSessionIDs() -> [SessionID] { Array(sessions.keys) }

    // MARK: - Internals

    private func sessionEnded(id: SessionID, exitCode: Int32) {
        if let session = sessions[id] { session.finish(exitCode: exitCode) }
        sessions.removeValue(forKey: id)
        processes.removeValue(forKey: id)
    }

    /// PTY master fd を read し続け、EOF で終了。actor の isolation 外で動かす。
    private static func readLoop(masterFD: Int32, session: LiveSession, process: Process,
                                 onExit: @escaping (Int32) async -> Void) async {
        let bufferSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buf.deallocate() }

        while true {
            let n = Darwin.read(masterFD, buf, bufferSize)
            if n > 0 {
                let data = Data(bytes: buf, count: n)
                session.push(data)
            } else if n == 0 {
                // EOF: 子が stdout/stderr を閉じた
                break
            } else {
                // n < 0: EIO (子が terminate して PTY が閉じた) 等
                break
            }
        }

        close(masterFD)
        process.waitUntilExit()
        await onExit(process.terminationStatus)
    }
}
