import Foundation

/// `wt` (worktrunk) CLI を subprocess で呼ぶ薄いラッパー。
///
/// 設計メモ (docs/spec.md §5.4):
/// - `wt switch` には JSON 出力オプションが無いため、create 後に `wt list --format=json`
///   を呼んで branch 名でフィルタしてパスを取得する 2 段階方式をとる。
/// - `wt` は zsh ではシェル関数だが、`Process` から呼ぶと PATH 上の実体を直接 exec するので
///   関数経由の副作用 (cd 等) は発生しない。
actor WorktreeService {

    // MARK: - Public types

    struct Worktree: Codable, Hashable {
        let path: String
        let branch: String
        let isCurrent: Bool?

        enum CodingKeys: String, CodingKey {
            case path, branch
            case isCurrent = "is_current"
        }
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case notFound              // wt バイナリが PATH に無い
        case commandFailed(exit: Int32, stderr: String)
        case worktreeMissing(branch: String)  // 作ったのに list に出てこない
        case decodeFailed(underlying: Swift.Error)

        var description: String {
            switch self {
            case .notFound:
                return "wt (worktrunk) not found in PATH. brew install worktrunk."
            case .commandFailed(let exit, let stderr):
                return "wt failed (exit \(exit)): \(stderr)"
            case .worktreeMissing(let branch):
                return "worktree for branch '\(branch)' not found after create"
            case .decodeFailed(let e):
                return "wt list JSON decode failed: \(e)"
            }
        }
    }

    // MARK: - Dependencies

    /// テストで差し替えられるようにしておく。
    private let wtExecutable: URL
    /// `wt` を実行する時のカレントディレクトリ (git リポジトリのルート)。
    private let repoURL: URL

    init(repoURL: URL, wtExecutable: URL? = nil) throws {
        self.repoURL = repoURL
        if let explicit = wtExecutable {
            self.wtExecutable = explicit
        } else {
            guard let found = Self.locate(executable: "wt") else { throw Error.notFound }
            self.wtExecutable = found
        }
    }

    private static func locate(executable name: String) -> URL? {
        // PATH + brew の典型的な場所を fallback として探す
        // (Xcode テストランナーは PATH を絞るため、Homebrew のパスが無い)
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let fallbacks = ["/opt/homebrew/bin", "/usr/local/bin", "/Users/\(NSUserName())/.local/bin"]
        let allPaths = envPaths + fallbacks

        var seen = Set<String>()
        for dir in allPaths where seen.insert(dir).inserted {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Operations

    /// 新規 worktree を作成し、そのパスを返す。
    func create(branch: String) async throws -> URL {
        _ = try await run(["switch", "-c", branch, "--no-cd"])
        let all = try await list()
        guard let found = all.first(where: { $0.branch == branch }) else {
            throw Error.worktreeMissing(branch: branch)
        }
        return URL(fileURLWithPath: found.path)
    }

    /// 全 worktree を一覧取得。
    func list() async throws -> [Worktree] {
        let data = try await run(["list", "--format=json"])
        do {
            return try JSONDecoder().decode([Worktree].self, from: data)
        } catch {
            throw Error.decodeFailed(underlying: error)
        }
    }

    /// worktree を削除。
    func remove(branch: String, force: Bool = false) async throws {
        var args = ["remove", branch]
        if force { args.append("--force") }
        _ = try await run(args)
    }

    // MARK: - Internals

    /// `wt <args>` を実行して stdout を返す。
    private func run(_ args: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = wtExecutable
        process.arguments = args
        process.currentDirectoryURL = repoURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            throw Error.commandFailed(exit: process.terminationStatus, stderr: stderr)
        }
        return stdoutData
    }
}
