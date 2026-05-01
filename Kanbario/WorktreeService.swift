import Foundation
import Darwin  // kill(2), SIGKILL — onCancel escalation 用 (Foundation 経由でも
               // 暗黙に見えるが、HookReceiver.swift と同じく明示する)

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

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            // `wt list --format=json` can return `branch: null` for detached or
            // special worktrees. Treat those as unmatchable entries instead of
            // failing the whole Start flow.
            branch = try container.decodeIfPresent(String.self, forKey: .branch) ?? ""
            isCurrent = try container.decodeIfPresent(Bool.self, forKey: .isCurrent)
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

    /// wt が「hook が設定されていない」旨を出すメッセージか判定する。
    ///
    /// `runPostCreateHooks` 側で `commandFailed` の stderr 本文に対して同じ
    /// 判定をしているが、progress 表示では stderr line が途中で渡ってくるので
    /// 各 line 単位で弾く必要がある。"No <name> hook configured in both user
    /// and project scope" / "...both user and project" のどちらも wt バージョン
    /// 差で出うるので、より緩い "No ... hook" 含みをパターンとして拾う。
    fileprivate static func shouldHideFromProgress(_ line: String) -> Bool {
        // 頭に "✗" / "×" / ANSI 色コードが付く可能性があるので contains でラフに。
        let hookKinds = ["post-switch", "post-start", "post-create", "pre-switch"]
        for kind in hookKinds {
            if line.contains("No \(kind) hook") { return true }
        }
        return false
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
    /// 各ステップで onProgress に「今なにをしているか」を通知し、UI が最新行
    /// として表示できるようにする。
    func createOrAttach(
        branch: String,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> (url: URL, wasCreated: Bool) {
        onProgress?("既存 worktree を確認しています…")
        let existing = try await list()
        if let found = existing.first(where: { $0.branch == branch }) {
            onProgress?("既存 worktree に attach します")
            return (URL(fileURLWithPath: found.path), false)
        }
        if branchExists(branch) {
            onProgress?("既存 branch から worktree を作成しています…")
            _ = try await run(
                ["switch", branch, "--no-cd", "-y"],
                onProgress: onProgress
            )
        } else {
            onProgress?("新規 branch + worktree を作成しています…")
            _ = try await run(
                ["switch", "-c", branch, "--no-cd", "-y"],
                onProgress: onProgress
            )
        }
        let all = try await list()
        guard let found = all.first(where: { $0.branch == branch }) else {
            throw Error.worktreeMissing(branch: branch)
        }
        let url = URL(fileURLWithPath: found.path)
        await runPostCreateHooks(
            worktreeURL: url, branch: branch, onProgress: onProgress
        )
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

    /// hook 名 → 設定されているかの可用性フラグキャッシュ。
    ///
    /// - 初回呼び出し時に wt を起動し、"No <hook> hook" と返ってきたら `false` を
    ///   cache して、**以降のタスクでは subprocess を起動せずスキップ**する。
    /// - `true` は明示的に cache しない (設定されているなら毎回走らせたい。
    ///   途中で設定を削除するケースでは false detection で自動的に false へ
    ///   rewrite される)。
    ///
    /// actor isolation により thread safe。アプリ起動期間中だけ有効なので、
    /// ユーザーが wt の hook を追加した直後は app 再起動で cache が消えて
    /// 新しい hook が拾われる。
    private var hookAvailability: [String: Bool] = [:]

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
    private func runPostCreateHooks(
        worktreeURL: URL,
        branch: String,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async {
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

        // 「未設定」と判定済みの hook は subprocess fork をスキップ。
        // 初回のみ wt を起動して availability を確定させる設計なので、
        // ユーザーがタスクを続けて start した時の体感レイテンシが短くなる。
        let toRun = steps.filter { hookAvailability[$0.label] != false }
        guard !toRun.isEmpty else { return }

        // post-switch と post-start は順序依存しない (どちらも一度きりの
        // setup 用 hook)。並列に走らせて「未設定でも 2 回待つ」状況を
        // 「未設定なら 1 回分の wait で終わる」に変える。
        let repoPath = self.repoURL.path
        _ = repoPath // captured via commonVars only (no explicit need here)
        await withTaskGroup(of: HookStepResult.self) { group in
            for step in toRun {
                group.addTask { [weak self] in
                    guard let self else {
                        return HookStepResult(label: step.label, outcome: .skipped)
                    }
                    return await self.runSingleHook(step: step, onProgress: onProgress)
                }
            }
            for await result in group {
                switch result.outcome {
                case .ok:
                    // 明示的 availability=true の cache は置かない
                    // (ユーザーが後から hook を消すケースを素直に検出するため)。
                    break
                case .notConfigured:
                    hookAvailability[result.label] = false
                case .failed(let message):
                    lastHookError = "\(result.label) hook failed: \(message)"
                case .skipped:
                    break
                }
            }
        }
    }

    /// hook 1 つ分を実行して結果を分類する。`runPostCreateHooks` の並列 loop
    /// から呼ばれる。silent skip / 実エラー / 成功を明確に区別して返す。
    private func runSingleHook(
        step: (label: String, args: [String]),
        onProgress: (@Sendable (String) -> Void)?
    ) async -> HookStepResult {
        onProgress?("\(step.label) hook を実行中…")
        do {
            _ = try await run(step.args, onProgress: onProgress)
            return HookStepResult(label: step.label, outcome: .ok)
        } catch {
            let description = "\(error)"
            if description.contains("No \(step.label) hook") {
                return HookStepResult(label: step.label, outcome: .notConfigured)
            }
            return HookStepResult(label: step.label, outcome: .failed(description))
        }
    }

    private struct HookStepResult: Sendable {
        let label: String
        let outcome: Outcome
        enum Outcome: Sendable {
            case ok
            case notConfigured
            case failed(String)
            case skipped
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
    /// node が command not found で失敗する**。
    ///
    /// **onProgress:** stdout + stderr を line 単位で callback。hook の
    /// `bun install` の進捗表示などを UI に流すのに使う。最新 1 行を UI が
    /// 保持する想定 (高頻度 call を想定しているので UI 側で debounce 不要)。
    private func run(
        _ args: [String],
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Data {
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

        // stdout / stderr を streaming 受けする line reader。progress と
        // 完了時の全 data 返却の両立のため Data も蓄積する。
        let stdoutReader = LineReader()
        let stderrReader = LineReader()
        // **Pipe-buffer deadlock 防止 (kanbario "planning delete が消えない" fix):**
        // Pipe バッファ (Darwin で ~64 KB) を drain せずに subprocess を放置すると、
        // subprocess の `write(2)` が EAGAIN 待ちで block → kanbario 側の
        // `waitUntilExit` も永久に戻らない、という古典的 deadlock になる。
        // 旧実装は `onProgress` 渡された時だけ readabilityHandler を設定して
        // いたため、`wt.remove` のような onProgress 無し path で出力量が多い
        // と planning task の Delete が固まっていた。onProgress の有無に
        // 関係なく **常に** 読み続けて、progress callback がある時だけ
        // line callback を呼ぶ構造に変える。
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let lines = stdoutReader.append(chunk)
            guard let onProgress else { return }
            for line in lines {
                if Self.shouldHideFromProgress(line) { continue }
                onProgress(line)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let lines = stderrReader.append(chunk)
            guard let onProgress else { return }
            for line in lines {
                // wt 本体が吐く「hook 未設定」系は silent skip 対象。
                // progress 表示にも漏らさない (ユーザー視点で「× …」が
                // カードに残って停滞しているように見える UX 劣化を回避)。
                if Self.shouldHideFromProgress(line) { continue }
                onProgress(line)
            }
        }

        try process.run()

        // Foundation.Process.waitUntilExit は同期。async 文脈から呼ぶため
        // continuation で別 thread に逃す。
        //
        // **Task cancel 対応:** withTaskCancellationHandler の onCancel で
        // subprocess を terminate する。これにより UI の「Cancel」ボタン
        // 押下で Task.cancel() → SIGTERM → waitUntilExit 解放 → continuation
        // resume の経路が成立する。terminate を呼ばずに Task.isCancelled
        // だけ見ていると、block 中の waitUntilExit が戻らず cancel 信号が
        // 届かないまま UI 上だけ「キャンセルした」表示になって subprocess が
        // 裏で延々残ってしまう。
        //
        // **SIGKILL escalation (kanbario の Starting 固着 fix):**
        // wt が起動する hook subprocess には `bun install` / `uv sync` のような
        // ネットワーク I/O で SIGTERM をすぐに飲まないものが混ざる。SIGTERM
        // 単発では `waitUntilExit` が永久に戻らず、Task chain が前に進めない
        // → `performStartTask` の defer が発火せず Starting バッジが残る /
        // 同 worktree への `wt remove` も後ろで詰まって Delete も効かない、
        // という連鎖症状になる。grace period を置いて SIGKILL に escalate
        // することで、SIGTERM を握りつぶす subprocess が居ても確実に解放
        // される。grace は「行儀の良い wt の post-flush に十分」「ユーザーが
        // 体感する固着としては許容できる」境界として 2 秒。
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    process.waitUntilExit()
                    cont.resume()
                }
            }
        } onCancel: {
            // onCancel は Task cancel の副作用として走る (isolation は
            // nonisolated)。Process は thread-safe な terminate() を持ち、
            // pid_t も capture 可能 (kill(2) は Darwin 経由で signal を直送)。
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            process.terminate()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                // 2 秒後にまだ生きている = SIGTERM を無視している subprocess。
                // SIGKILL は kernel が直接終了させるので確実に exit する。
                // 既に死んでいる (waitUntilExit が戻った) 場合は isRunning が
                // false なので no-op。pid 再利用衝突を避けるために isRunning
                // を必ず先に確認する。
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }

        // streaming handler を外した後、残っている data を一括回収。
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrTail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutAll = stdoutReader.flush() + stdoutTail
        let stderrAll = stderrReader.flush() + stderrTail

        // cancel されたときは exit code 非 0 で戻ってくるが、それは「ユーザー
        // がキャンセルした」こと自体の表現として CancellationError に変換。
        // caller (startTask) は catch で isCancelled を見て silent 終了する。
        if Task.isCancelled {
            throw CancellationError()
        }
        if process.terminationStatus != 0 {
            let stderr = String(data: stderrAll, encoding: .utf8) ?? ""
            throw Error.commandFailed(exit: process.terminationStatus, stderr: stderr)
        }
        return stdoutAll
    }
}

/// Process の stdout / stderr を line buffer で切り出す軽量 helper。
/// readabilityHandler は async background で呼ばれるため lock 必須。
/// `@unchecked Sendable` で Swift 6 concurrency と握手する
/// (lock-protected な mutable state)。
///
/// **設計意図:** `append()` は progress 通知用に改行で切った lines を返しつつ、
/// 元データは `allData` に残す (非破壊)。`flush()` はその累積 Data を返すので、
/// 呼び出し側は「stream 読み進めつつ最後に全体 Data を取得」できる。
/// この二重保持が無いと、行単位 progress を通知した時点で stderr の原文が
/// 消え、Process 失敗時のエラーメッセージが空になる (hook silent-skip 判定
/// が働かなくなる) というバグを生む。
private final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    /// 未改行の末尾 — 次 append でこれと結合してから改行検索する。
    private var buffer = Data()
    /// 全 chunk の累積 — flush 時に全体 Data を返す用。
    private var allData = Data()

    /// chunk を追加し、改行で切れた確定 line の配列を返す。原始 data は
    /// `allData` に保存されるので flush() で完全再現できる。
    func append(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        allData.append(chunk)
        buffer.append(chunk)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineBytes = buffer.prefix(upTo: nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let line = String(data: lineBytes, encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { lines.append(trimmed) }
            }
        }
        return lines
    }

    /// それまでに append された全 chunk を Data として返し、内部 buffer を空に。
    func flush() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let data = allData
        allData.removeAll()
        buffer.removeAll()
        return data
    }
}
