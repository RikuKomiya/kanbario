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

    /// 指定 branch について「既存 worktree を使う」か「新規作成」を自動判別する。
    ///
    /// 判別フロー:
    /// 1. `wt list` に同じ branch の worktree が既にある → **attach**
    ///    (hook 再実行せずパスだけ返す)
    /// 2. branch 自体は git に存在する (`git rev-parse`) → `wt switch <branch>`
    ///    で -c なしの switch。worktree は新規作成 + hook 実行。
    /// 3. branch も無い → `wt switch -c <branch>` で両方新規作成 + hook 実行。
    func createOrAttach(branch: String) async throws -> (url: URL, wasCreated: Bool) {
        let existing = try await list()
        if let found = existing.first(where: { $0.branch == branch }) {
            return (URL(fileURLWithPath: found.path), false)
        }
        if branchExists(branch) {
            _ = try await run(["switch", branch, "--no-cd", "-y"])
        } else {
            _ = try await run(["switch", "-c", branch, "--no-cd", "-y"])
        }
        let all = try await list()
        guard let found = all.first(where: { $0.branch == branch }) else {
            throw Error.worktreeMissing(branch: branch)
        }
        let url = URL(fileURLWithPath: found.path)
        await runPostCreateHooks(worktreeURL: url, branch: branch)
        return (url, true)
    }

    /// repo の local branch 一覧 (NewTaskSheet の picker 用)。失敗時は空配列。
    func allBranches() async -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", repoURL.path, "branch", "--list",
            "--format=%(refname:short)"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        guard process.terminationStatus == 0 else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `git rev-parse --verify --quiet <branch>` で branch の存在判定。
    /// 失敗 or 未解決なら false。switch -c 側にフォールバックする前提なので
    /// false positive ではなく false negative を許容する構造。
    private func branchExists(_ branch: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", repoURL.path, "rev-parse", "--verify", "--quiet", branch
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// 新規 worktree を作成し、そのパスを返す (レガシー; 新コードは
    /// `createOrAttach` を使うこと)。
    ///
    /// `-y` は **必須**: wt は commit 等で approval prompt を出すことがあり、
    /// subprocess では stdin が無いので無反応 = ハングするため。
    func create(branch: String) async throws -> URL {
        _ = try await run(["switch", "-c", branch, "--no-cd", "-y"])
        let all = try await list()
        guard let found = all.first(where: { $0.branch == branch }) else {
            throw Error.worktreeMissing(branch: branch)
        }
        let worktreeURL = URL(fileURLWithPath: found.path)

        // 明示的な hook 発火。失敗は warning 扱いで握る (UI 側で lastHookError を拾える)。
        await runPostCreateHooks(worktreeURL: worktreeURL, branch: branch)

        return worktreeURL
    }

    /// post-create hook 実行中に直近のエラーがあれば入る。UI から optional で拾える。
    /// 成功時に nil にリセットする。
    private(set) var lastHookError: String?

    /// `wt hook post-switch` + `post-start` を直列 foreground 実行する。
    /// どちらかが失敗したら lastHookError に積むが throw しない。
    ///
    /// **cwd 決定:** `-C` には **main repo root** (= `repoURL`) を渡す。
    /// worktree 側を cwd にすると wt は worktree 内の `.config/wt.toml` を
    /// project config として探してしまい、ターゲットプロジェクトに既に
    /// 置いてある hook 設定 (main repo root 側) を見失う。
    ///
    /// **template 変数:** `--var worktree_path=<abs>` と `--var branch=<name>`
    /// を明示注入し、hook スクリプトが `{{ worktree_path }}` / `{{ branch }}`
    /// を展開できるようにする。cwd とは独立に値を渡すのが worktrunk の意図
    /// 通りの使い方。
    ///
    /// **未設定は成功扱い:** wt は hook 未定義時に exit 1 + stderr で
    /// "No <kind> hook configured" を返す。これは kanbario の意図通り
    /// (設定していないなら実行不要) なので silent skip。
    private func runPostCreateHooks(worktreeURL: URL, branch: String) async {
        lastHookError = nil
        let commonVars = [
            "--var", "worktree_path=\(worktreeURL.path)",
            "--var", "branch=\(branch)",
        ]
        let steps: [(label: String, args: [String])] = [
            ("post-switch", ["-C", repoURL.path, "hook", "post-switch",
                             "--foreground", "-y"] + commonVars),
            ("post-start",  ["-C", repoURL.path, "hook", "post-start",
                             "--foreground", "-y"] + commonVars),
        ]
        for step in steps {
            do {
                _ = try await run(step.args)
            } catch {
                // wt は未設定時に exit 1 + "No <kind> hook configured" を返す。
                // 実体 hook の失敗 (script error 等) はメッセージに hook name を
                // 含まないので、引き続き警告化する。
                let description = "\(error)"
                if description.contains("No \(step.label) hook configured") {
                    continue
                }
                lastHookError = "\(step.label) hook failed: \(description)"
            }
        }
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

    /// 指定 worktree に uncommitted な変更があるか調べる (git status --porcelain
    /// の出力が非空なら dirty)。git は PATH に依存しないよう `/usr/bin/git`
    /// 固定で起動する (macOS 標準位置)。
    ///
    /// 失敗時は保守的に `false` (= clean 扱い) を返す。判定不能なケースで
    /// 削除確認 dialog が出ないのは不便ではあるが、判定できないのに
    /// 「変更があるかも」と誤報するよりは UX が素直。
    func isDirty(worktreePath: URL) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", worktreePath.path, "status", "--porcelain"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return !data.isEmpty
    }

    /// worktree を削除。
    ///
    /// kanbario では「タスクを done / delete した = もう worktree は要らない」
    /// という強い意味合いなので、以下を **常時** 付ける:
    /// - `-y / --yes`: approval prompt を skip (stdin 無し環境で必須)
    /// - `--force-delete`: unmerged branch でも消す (kanbario は review 段階で
    ///   merge 済とは限らないため、強制削除が現実的な挙動)
    ///
    /// `force = true` の場合は更に `--force` を追加して untracked files 併存
    /// でも消す (build 成果物等、claude が残した artifacts をまとめて掃除)。
    ///
    /// **冪等性:** wt が "No branch named ..." と言って exit 1 を返すケースは
    /// **成功扱いに読み替える**。task.branch が指す worktree が wt 側で
    /// 存在しない = 既に削除済 or そもそも未作成 という状態で、kanbario 視点の
    /// 目的 (消えている) は既に達成されているため。この読み替えが無いと、
    /// race / 手動削除 / 古い state.json 残骸で毎回 alert が出てしまう。
    func remove(branch: String, force: Bool = false) async throws {
        var args = ["remove", "-y", "--force-delete", branch]
        if force { args.append("--force") }
        do {
            _ = try await run(args)
        } catch Error.commandFailed(_, let stderr)
            where stderr.contains("No branch named") {
            // 既に消えている / 登録されていない → Remove 目的は達成済
            return
        }
    }

    // MARK: - Internals

    /// `wt <args>` を実行して stdout を返す。
    ///
    /// **PATH の augment が必須:** kanbario は GUI launched process なので、
    /// 継承する PATH は launchd の thin 版 (`/usr/bin:/bin:/usr/sbin:/sbin`) に
    /// 絞られている。wt は hook script を `bash -c "bun install"` のように
    /// 起動するため、この thin PATH のまま渡すと **子孫プロセスで bun / uv /
    /// node が command not found で失敗する**。結果: kanbario から呼んだ時
    /// だけ post-start hook が無言でコケる現象になる。
    ///
    /// `ClaudeSessionFactory.augmentedPATH` が既に Homebrew / node version
    /// manager / ~/.bun/bin 等を網羅しているので、そのまま流用する。LANG /
    /// LC_CTYPE も同じ理由で設定 (wt 内部の text 処理で必要になり得る)。
    private func run(_ args: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = wtExecutable
        process.arguments = args
        process.currentDirectoryURL = repoURL

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ClaudeSessionFactory.augmentedPATH(current: env["PATH"])
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if env["LC_CTYPE"] == nil { env["LC_CTYPE"] = "UTF-8" }
        process.environment = env

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
