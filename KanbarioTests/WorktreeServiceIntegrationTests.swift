import Testing
import Foundation
@testable import Kanbario

/// 実 `wt` (worktrunk) バイナリと通信する統合テスト。
/// CI で worktrunk 未インストールなら SKIP するため、事前に wt の存在をチェックする。
@Suite("WorktreeService integration with real wt CLI")
struct WorktreeServiceIntegrationTests {

    // MARK: - Fixture

    /// テスト用の一時 git repo を作成。main に空コミット 1 個だけの最小状態。
    static func makeTempRepo() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kanbario-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        try runGit(["init", "-q", "-b", "main"], at: tmp)
        try runGit(["config", "user.email", "test@example.com"], at: tmp)
        try runGit(["config", "user.name",  "Test"], at: tmp)
        try runGit(["commit", "--allow-empty", "-q", "-m", "initial"], at: tmp)
        return tmp
    }

    static func runGit(_ args: [String], at url: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = url
        p.standardOutput = Pipe()
        p.standardError  = Pipe()
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw TestError.gitFailed(args.joined(separator: " "))
        }
    }

    enum TestError: Error { case gitFailed(String); case wtNotInstalled }

    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        // wt が兄弟ディレクトリに worktree を作るので、親の下も掃除する必要あり
        let parent = url.deletingLastPathComponent()
        let base = url.lastPathComponent
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.hasPrefix(base) {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    // MARK: - Tests

    @Test("wt バイナリが PATH にある (前提条件)")
    func wtIsInstalled() throws {
        let service = try WorktreeService(repoURL: URL(fileURLWithPath: "/tmp"))
        _ = service  // 初期化エラーが出なければ OK
    }

    @Test("wt list は temp repo で空配列または初期 worktree を返す")
    func listOnFreshRepo() async throws {
        let repo = try Self.makeTempRepo()
        defer { Self.cleanup(repo) }

        let svc = try WorktreeService(repoURL: repo)
        let list = try await svc.list()
        // main worktree 自身は出るはず
        #expect(!list.isEmpty)
        #expect(list.contains(where: { $0.branch == "main" }))
    }

    @Test("create → list で新ブランチが見えて、remove で消える")
    func createListRemoveCycle() async throws {
        let repo = try Self.makeTempRepo()
        defer { Self.cleanup(repo) }

        let svc = try WorktreeService(repoURL: repo)
        let branch = "kanbario/test-\(UUID().uuidString.prefix(6))"

        // create
        let wtURL = try await svc.create(branch: branch)
        #expect(FileManager.default.fileExists(atPath: wtURL.path))

        // list に出ること
        let after = try await svc.list()
        #expect(after.contains(where: { $0.branch == branch }))

        // remove
        try await svc.remove(branch: branch, force: true)
        let afterRemove = try await svc.list()
        #expect(!afterRemove.contains(where: { $0.branch == branch }))
    }
}
