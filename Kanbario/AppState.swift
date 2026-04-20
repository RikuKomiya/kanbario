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

    /// 現在 live な claude セッション: taskID -> TerminalSurface (libghostty が
    /// PTY と子プロセスを所有する。Milestone D 以降はここで保持するだけで、
    /// stdout の吸い出し・ログ蓄積はやらない — libghostty が GPU に描画する)。
    var activeSurfaces: [UUID: TerminalSurface] = [:]

    /// Claude hook で受け取った活動状態。surface が消えれば nil に戻す。
    /// 詳細画面のバッジ表示用 (Models.swift の `ClaudeActivity` 参照)。
    var activitiesByTaskID: [UUID: ClaudeActivity] = [:]

    /// デモ用のデフォルトプロジェクト。MVP は 1 プロジェクト前提。
    let defaultProject: Project

    /// repoPath が設定されるまでは nil。設定時に init (throws)、失敗時は lastError を立てる。
    private(set) var worktreeService: WorktreeService?

    /// 永続化先 (テストから差し替え可能)。
    private let saveURL: URL

    /// Claude CLI からの hook を Unix socket で受ける常駐 listener。
    /// init で立ち上がり、deinit で stop する。
    private var hookReceiver: HookReceiver?

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
        startHookReceiver()
    }

    deinit {
        hookReceiver?.stop()
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

    /// Start ボタンから呼ばれる。wt create → TerminalSurface (libghostty 側で
    /// fork+execve) → inProgress へ同期遷移。プロセス exit は
    /// `handleSurfaceClosed` (close_surface_cb からの callback) で review に
    /// 飛ばす。
    func startTask(_ task: TaskCard) async {
        guard let wt = worktreeService else {
            lastError = "リポジトリを選んでください (Choose Repo…)"
            return
        }
        guard task.status == .planning else { return }
        guard activeSurfaces[task.id] == nil else { return }

        do {
            let worktreeURL = try await wt.create(branch: task.branch)
            let surface = try ClaudeSessionFactory.makeSurface(
                task: task, worktreeURL: worktreeURL
            )
            activeSurfaces[task.id] = surface
            applyStatus(id: task.id, to: .inProgress)
        } catch {
            lastError = "Start failed: \(error)"
        }
    }

    /// 手動で claude を止める。libghostty に gracefully close を依頼すると、
    /// 子プロセス (claude) に SIGHUP が届き、その後 close_surface_cb が発火。
    /// handleSurfaceClosed で review に遷移する。
    func stopTask(id: UUID) {
        activeSurfaces[id]?.requestClose()
    }

    /// `GhosttyNSView.onCloseRequested` 経由で呼ばれる。libghostty が子プロセス
    /// 終了を検知したタイミングで review に飛ばす。
    func handleSurfaceClosed(taskID: UUID) {
        guard activeSurfaces[taskID] != nil else { return }
        activeSurfaces.removeValue(forKey: taskID)
        activitiesByTaskID.removeValue(forKey: taskID)
        applyStatus(id: taskID, to: .review)
    }

    // MARK: - Hook receiver

    /// Claude shim → CLI → socket → ここ (MainActor) の経路で event を受ける。
    ///
    /// Kanban のカラム意味論:
    ///   - inProgress = claude が能動的に作業中 (tool 実行 / reasoning)
    ///   - review     = claude のターンが終わってユーザー入力待ち (cmux の "needsInput")
    ///                  または claude プロセスが exit して再開不可
    ///   - done       = ユーザーが完了とした (手動 drag、cleanup 発火)
    ///
    /// したがって claude が動くたびにカードが inProgress ↔ review を行き来する。
    /// state machine (canTransition) は両方向を既に許可しているので、ここでは
    /// hook event を素直にカラム遷移へマッピングする。
    func handleHook(_ message: HookMessage) {
        guard let id = UUID(uuidString: message.surfaceID) else { return }
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        let current = tasks[idx].status

        switch message.event {
        case "session-start":
            // startTask が既に planning → inProgress に飛ばしているはず。
            // 念のため planning に居る場合だけ前進させる (kanbario 外で同じ
            // shim 設定を踏んだ場合の保護)。
            if current == .planning {
                applyStatusFromHook(idx: idx, to: .inProgress)
            }
            activitiesByTaskID[id] = .running

        case "prompt-submit", "pre-tool-use":
            // ユーザー入力 or tool 実行 = claude が能動的に動いている。
            // review (= ユーザー待ち) からの「再開」を含めて inProgress へ。
            if current == .review || current == .planning {
                applyStatusFromHook(idx: idx, to: .inProgress)
            }
            activitiesByTaskID[id] = .running

        case "stop":
            // ターン終了 = claude が「次のユーザー入力を待っています」状態。
            // Kanban 上で見える状態遷移として review カラムへ移す。
            // done に到達済 (ユーザーが先に完了とした) なら触らない。
            if current == .inProgress {
                applyStatusFromHook(idx: idx, to: .review)
            }
            activitiesByTaskID[id] = .needsInput

        case "session-end":
            // claude プロセス exit。close_surface_cb 経路と冗長 (どちらか
            // 早い方で review に飛ばせば良い)。activity は exit を意味する
            // 専用値が無いので消してしまう (= UI からは review 静止状態)。
            if current == .inProgress {
                applyStatusFromHook(idx: idx, to: .review)
            }
            activitiesByTaskID.removeValue(forKey: id)

        case "notification":
            // MVP では未対応 (UNUserNotificationCenter は entitlement が要るため
            // 後回し)。Stop による review カラム遷移が「ユーザーの番」を
            // ボード上で表現するので、最低限の可視化はカバーできている。
            break

        default:
            break
        }
    }

    /// hook 経由の status 書き換えは canTransition チェックを通さない
    /// (hook は authoritative)。idx は呼び出し側で resolve 済み前提。
    private func applyStatusFromHook(idx: Int, to status: TaskStatus) {
        tasks[idx].status = status
        tasks[idx].updatedAt = Date()
        save()
    }

    private func startHookReceiver() {
        let socketPath = Self.defaultHookSocketPath()
        let receiver = HookReceiver(socketPath: socketPath) { [weak self] message in
            Task { @MainActor in
                self?.handleHook(message)
            }
        }
        do {
            try receiver.start()
            hookReceiver = receiver
        } catch {
            lastError = "HookReceiver start failed: \(error)"
        }
    }

    /// CLI と app の両方が参照する socket path。Application Support 配下。
    static func defaultHookSocketPath() -> String {
        defaultSaveURL()
            .deletingLastPathComponent()
            .appendingPathComponent("hook.sock")
            .path
    }

    /// review → done drag で呼ばれる。surface teardown → wt remove → done へ遷移。
    /// wt remove が失敗しても done 状態までは進める (worktree は手動削除できる)。
    func moveToDone(task: TaskCard) async {
        guard task.status == .review else { return }

        if let surface = activeSurfaces[task.id] {
            await MainActor.run {
                surface.teardown()
            }
            activeSurfaces.removeValue(forKey: task.id)
            activitiesByTaskID.removeValue(forKey: task.id)
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
