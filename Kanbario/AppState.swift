import Foundation
import Observation

/// アプリ全体のルート状態。SwiftUI View から `@Environment(AppState.self)` で参照。
///
/// 永続化: `tasks` と `repoPath` を JSON にして
/// `~/Library/Application Support/kanbario/state.json` に書く。
/// GRDB の導入は Commit 2 (hook 統合) で event log が必要になった時点で行う。
@Observable
final class AppState {
    /// 表示中の全タスク。カラム分けは `tasks(in:)` で取得。
    var tasks: [TaskCard] = []

    /// 詳細画面に表示中のタスク。nil なら詳細なし。
    var selectedTaskID: UUID?

    /// 現在 drag 中のタスク ID。drag 開始時に set、drop または timeout で nil に戻る。
    /// UI 側で source card を opacity 0 にするのに使う。
    var draggingTaskID: UUID?

    /// 選択中のリポジトリのパス (空 = 未設定)。Start ボタンを有効化する前提。
    var repoPath: String = ""

    /// UI に表示するエラー (alert の source of truth)。
    var lastError: String?

    /// 現在 live な claude セッション: taskID -> SessionManager.SessionID。
    /// done 時の cleanup 対象を引くのに使う。
    var activeSessions: [UUID: SessionManager.SessionID] = [:]

    /// Claude の stdout を積むバッファ。taskID -> tail (最大 `maxLogBytes` 文字)。
    /// ANSI escape は粗く剥がして可読テキストに寄せる (perfect な TUI 再描画は
    /// libghostty 導入後に任せる。いまは「何が起きているか」を確認できれば十分)。
    var sessionLogs: [UUID: String] = [:]

    /// セッション終了時の exit code。review 状態の下に表示する。
    var sessionExitCodes: [UUID: Int32] = [:]

    /// 1 セッションあたりのログ tail 上限。これを超えたら先頭を捨てる。
    private static let maxLogBytes = 8 * 1024

    /// デモ用のデフォルトプロジェクト。MVP は 1 プロジェクト前提。
    let defaultProject: Project

    /// worktree と claude spawn を担う背後アクター。MainActor からは await 越しに呼ぶ。
    let sessionManager = SessionManager()

    /// repoPath が設定されるまでは nil。設定時に init (throws)、失敗時は lastError を立てる。
    private(set) var worktreeService: WorktreeService?

    /// 永続化先 (テストから差し替え可能)。
    private let saveURL: URL

    init(saveURL: URL? = nil) {
        self.saveURL = saveURL ?? Self.defaultSaveURL()
        self.defaultProject = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Kanbario",
            repoPath: "",
            defaultBranch: "main",
            createdAt: Date()
        )
        if let loaded = Self.load(from: self.saveURL) {
            self.tasks = loaded.tasks
            self.repoPath = loaded.repoPath
        }
        // repoPath が生きていれば WorktreeService を立ち上げる。起動時に
        // wt バイナリが PATH から消えている可能性を握りつぶしたくないので
        // 失敗したら lastError に流して UI に見せる。
        if !repoPath.isEmpty {
            configureWorktreeService()
        }
    }

    // MARK: - Queries

    /// 指定カラムに属するタスクを、更新日の新しい順で返す。
    func tasks(in status: TaskStatus) -> [TaskCard] {
        tasks
            .filter { $0.status == status }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 選択中のタスク (無ければ nil)。
    var selectedTask: TaskCard? {
        guard let id = selectedTaskID else { return nil }
        return tasks.first(where: { $0.id == id })
    }

    /// drag 中のタスク (無ければ nil)。drop 先 column のゴーストカード表示に使う。
    var draggingTask: TaskCard? {
        guard let id = draggingTaskID else { return nil }
        return tasks.first(where: { $0.id == id })
    }

    /// Start ボタンを有効化できる状態か。
    var canStartTasks: Bool { worktreeService != nil }

    // MARK: - Mutations

    /// 新規タスクを planning 列に追加する。
    func addTask(title: String, body: String) {
        let id = UUID()
        let now = Date()
        let task = TaskCard(
            id: id,
            projectID: defaultProject.id,
            title: title,
            body: body,
            status: .planning,
            branch: "kanbario/\(id.uuidString.prefix(6).lowercased())",
            createdAt: now,
            updatedAt: now
        )
        tasks.append(task)
        save()
    }

    /// タスクのステータスを変更する。
    /// review → done は worktree cleanup + claude kill を伴うので非同期分岐。
    /// それ以外 (planning → inProgress 等) は従来どおり同期で書き換える。
    func moveTask(id: UUID, to newStatus: TaskStatus) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        let current = tasks[idx].status
        guard current.canTransition(to: newStatus) else { return }

        if current == .review && newStatus == .done {
            let taskSnapshot = tasks[idx]
            Task { await self.moveToDone(task: taskSnapshot) }
            return
        }

        tasks[idx].status = newStatus
        tasks[idx].updatedAt = Date()
        save()
    }

    /// タスクを削除する (cleanup 後に呼ばれる想定)。
    func deleteTask(id: UUID) {
        tasks.removeAll(where: { $0.id == id })
        if selectedTaskID == id { selectedTaskID = nil }
        save()
    }

    // MARK: - Repo selection

    /// NSOpenPanel で選ばれた URL を repoPath として採用する。
    /// WorktreeService の初期化に失敗した場合は lastError を立てる。
    func setRepoPath(_ path: String) {
        repoPath = path
        configureWorktreeService()
        save()
    }

    private func configureWorktreeService() {
        do {
            let url = URL(fileURLWithPath: repoPath)
            worktreeService = try WorktreeService(repoURL: url)
        } catch {
            worktreeService = nil
            lastError = "WorktreeService init failed: \(error)"
        }
    }

    // MARK: - Claude lifecycle

    /// Start ボタンから呼ばれる。wt create → claude spawn → inProgress へ同期遷移 →
    /// termination を watch して完了時に review へ移す。失敗時は lastError を立てる。
    func startTask(_ task: TaskCard) async {
        guard let wt = worktreeService else {
            lastError = "リポジトリを選んでください (Choose Repo…)"
            return
        }
        guard task.status == .planning else { return }
        guard activeSessions[task.id] == nil else { return }

        do {
            let worktreeURL = try await wt.create(branch: task.branch)
            let session = try await sessionManager.startClaude(
                task: task, worktreeURL: worktreeURL
            )
            activeSessions[task.id] = session.id
            sessionLogs[task.id] = ""
            sessionExitCodes.removeValue(forKey: task.id)
            applyStatus(id: task.id, to: .inProgress)

            let taskID = task.id

            // PTY stdout を吸い出して sessionLogs[taskID] に追記する。ANSI を
            // 剥がして読める形にする (libghostty 導入まではこれで凌ぐ)。
            _Concurrency.Task { @MainActor [weak self] in
                for await chunk in session.bytes {
                    self?.appendLog(taskID: taskID, data: chunk)
                }
            }

            // PTY 終端を監視して自動で review に飛ばす。
            // Session は actor 越しの class なので capture に weak は不要 (session 自身は
            // SessionManager が保持)。終了後に activeSessions から drop。
            _Concurrency.Task { @MainActor [weak self] in
                for await exitCode in session.termination {
                    guard let self else { return }
                    self.sessionExitCodes[taskID] = exitCode
                    self.activeSessions.removeValue(forKey: taskID)
                    self.applyStatus(id: taskID, to: .review)
                }
            }
        } catch {
            lastError = "Start failed: \(error)"
        }
    }

    /// 手動で claude を止める。SIGTERM 送信 → PTY EOF → termination watcher
    /// 経由で review に遷移する。
    func stopTask(id: UUID) async {
        guard let sessionID = activeSessions[id] else { return }
        await sessionManager.kill(id: sessionID)
    }

    /// 標準入力に文字列を流す (末尾に \n を足す)。
    /// 返り値は成功/失敗の情報を出すためだが、UI はいまは気にしない。
    func sendInput(taskID: UUID, text: String) async {
        guard let sessionID = activeSessions[taskID] else { return }
        let bytes = (text + "\n").data(using: .utf8) ?? Data()
        do {
            try await sessionManager.write(to: sessionID, bytes: bytes)
        } catch {
            lastError = "入力送信失敗: \(error)"
        }
    }

    /// PTY から届いたバイトを String に落として ANSI を粗く剥がしてから追記する。
    /// tail 上限を超えたら先頭を捨てる (log が無限増殖しないように)。
    private func appendLog(taskID: UUID, data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let cleaned = Self.stripANSI(text)
        var current = sessionLogs[taskID, default: ""]
        current += cleaned
        if current.count > Self.maxLogBytes {
            current = String(current.suffix(Self.maxLogBytes))
        }
        sessionLogs[taskID] = current
    }

    /// ANSI CSI シーケンス (`ESC[...letter`) と単発制御文字を剥がす。
    /// 完全な VT 解釈ではないが、claude TUI の出力から可読テキストを拾うには十分。
    static func stripANSI(_ s: String) -> String {
        // CSI (cursor pos、色など) を削除
        var out = s.replacingOccurrences(
            of: "\u{001B}\\[[0-9;?]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
        // OSC (タイトル設定等) を BEL / ESC\ まで削除
        out = out.replacingOccurrences(
            of: "\u{001B}\\][^\u{0007}\u{001B}]*(\u{0007}|\u{001B}\\\\)",
            with: "",
            options: .regularExpression
        )
        // 残った単発 ESC + 次の 1 文字を削除 (=, >, M, 7, 8 等)
        out = out.replacingOccurrences(
            of: "\u{001B}.",
            with: "",
            options: .regularExpression
        )
        // キャリッジリターンは改行に寄せる (スクロール表示を楽にするため)
        out = out.replacingOccurrences(of: "\r\n", with: "\n")
        out = out.replacingOccurrences(of: "\r", with: "\n")
        return out
    }

    /// review → done drag で呼ばれる。claude kill → wt remove → done へ遷移。
    /// wt remove が失敗しても done 状態までは進める (worktree は手動削除できる)。
    func moveToDone(task: TaskCard) async {
        guard task.status == .review else { return }

        if let sessionID = activeSessions[task.id] {
            await sessionManager.kill(id: sessionID)
            activeSessions.removeValue(forKey: task.id)
        }

        if let wt = worktreeService {
            do {
                try await wt.remove(branch: task.branch, force: true)
            } catch {
                lastError = "wt remove failed: \(error) (worktree を手動削除してください)"
            }
        }

        applyStatus(id: task.id, to: .done)
    }

    /// 状態変更を tasks に反映し、永続化する低レベル関数。MainActor 前提。
    /// canTransition チェックを通さないので、呼び出し側が責任を持つこと。
    private func applyStatus(id: UUID, to status: TaskStatus) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].status = status
        tasks[idx].updatedAt = Date()
        save()
    }

    // MARK: - Persistence

    /// state.json のオンディスク形式。v1 は bare [TaskCard] だったので load で
    /// 両フォーマットをサポートする (書き出しは常にこの型)。
    struct PersistedState: Codable {
        var tasks: [TaskCard]
        var repoPath: String
    }

    static func defaultSaveURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("kanbario")
        try? FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true
        )
        return appSupport.appendingPathComponent("state.json")
    }

    private func save() {
        let snapshot = PersistedState(tasks: tasks, repoPath: repoPath)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: saveURL, options: .atomic)
        } catch {
            print("[AppState] save failed: \(error)")
        }
    }

    private static func load(from url: URL) -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // v2 (dict with tasks + repoPath) を先に試し、失敗したら v1 (bare array) に落とす。
        if let v2 = try? decoder.decode(PersistedState.self, from: data) {
            return v2
        }
        if let v1 = try? decoder.decode([TaskCard].self, from: data) {
            return PersistedState(tasks: v1, repoPath: "")
        }
        return nil
    }
}
