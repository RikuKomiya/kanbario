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
