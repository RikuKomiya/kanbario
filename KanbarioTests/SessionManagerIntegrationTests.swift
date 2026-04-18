import Testing
import Foundation
@testable import Kanbario

@Suite("SessionManager integration — PTY + Process")
struct SessionManagerIntegrationTests {

    @Test("/bin/echo hello の出力を PTY 経由で読める")
    func spawnEchoAndRead() async throws {
        let mgr = SessionManager()
        let session = try await mgr.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello", "from", "pty"]
        )

        var collected = Data()
        for await chunk in session.bytes {
            collected.append(chunk)
        }
        let text = String(data: collected, encoding: .utf8) ?? ""
        #expect(text.contains("hello from pty"), "got: \(text)")

        // 終了コードを受け取れる
        var exitCode: Int32? = nil
        for await code in session.termination {
            exitCode = code
        }
        #expect(exitCode == 0)
    }

    @Test("bash を起動して stdin に書き込んだコマンドが実行される")
    func spawnBashAndWriteCommand() async throws {
        let mgr = SessionManager()
        let session = try await mgr.start(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", "read LINE && echo \"GOT: $LINE\""]
        )

        // stdin に書き込む
        try await mgr.write(to: session.id, bytes: "PING\n".data(using: .utf8)!)

        var collected = Data()
        for await chunk in session.bytes {
            collected.append(chunk)
        }
        let text = String(data: collected, encoding: .utf8) ?? ""
        #expect(text.contains("GOT: PING"), "got: \(text)")
    }
}
