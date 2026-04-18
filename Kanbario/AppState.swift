import Foundation
import Observation

/// アプリ全体のルート状態。SwiftUI View から `@Environment(AppState.self)` で参照。
///
/// 永続化: `tasks` を JSON にして `~/Library/Application Support/kanbario/state.json` に書く。
/// 直 SQLite3 や GRDB は Milestone C 以降 (events テーブルが必要になった時) で導入予定。
@Observable
final class AppState {
    /// 表示中の全タスク。カラム分けは `tasks(in:)` で取得。
    var tasks: [TaskCard] = []

    /// 詳細画面に表示中のタスク。nil なら詳細なし。
    var selectedTaskID: UUID?

    /// 現在 drag 中のタスク ID。drag 開始時に set、drop または timeout で nil に戻る。
    /// UI 側で source card を opacity 0 にするのに使う。
    var draggingTaskID: UUID?

    /// デモ用のデフォルトプロジェクト。MVP は 1 プロジェクト前提。
    let defaultProject: Project

    /// 永続化先 (テストから差し替え可能)。
    private let saveURL: URL

    init(saveURL: URL? = nil) {
        self.saveURL = saveURL ?? Self.defaultSaveURL()
        self.defaultProject = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,  // MVP は固定
            name: "Kanbario",
            repoPath: "",
            defaultBranch: "main",
            createdAt: Date()
        )
        // 既存ファイルがあればロード
        if let loaded = Self.load(from: self.saveURL) {
            self.tasks = loaded
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

    /// タスクのステータスを変更する。遷移が許可されていない場合は何もしない。
    func moveTask(id: UUID, to newStatus: TaskStatus) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[idx].status.canTransition(to: newStatus) else { return }
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

    // MARK: - Persistence

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
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(tasks)
            try data.write(to: saveURL, options: .atomic)
        } catch {
            // 書き込み失敗は握りつぶす (UI をブロックしない)。
            // 本番では Sentry 等に送るべき。
            print("[AppState] save failed: \(error)")
        }
    }

    private static func load(from url: URL) -> [TaskCard]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([TaskCard].self, from: data)
    }
}
