import Testing
import Foundation
@testable import Kanbario

@Suite("AppState mutations and persistence")
@MainActor
struct AppStateTests {

    /// 各テストで独立した saveURL を使う (real state.json を汚染しないため)。
    private static func tempSaveURL() -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanbario-test-\(UUID().uuidString.prefix(8)).json")
        return tmp
    }

    // MARK: - addTask

    @Test("addTask: 新規タスクが planning 列に入る")
    func addTaskPutsInPlanning() {
        let saveURL = Self.tempSaveURL()
        defer { try? FileManager.default.removeItem(at: saveURL) }

        let state = AppState(saveURL: saveURL)
        state.addTask(title: "T1", body: "do stuff")

        #expect(state.tasks.count == 1)
        let t = state.tasks[0]
        #expect(t.title == "T1")
        #expect(t.body == "do stuff")
        #expect(t.status == .planning)
        #expect(t.branch.hasPrefix("kanbario/"))
        #expect(t.createdAt == t.updatedAt)  // 初期は同じ時刻
    }

    @Test("addTask: 複数追加で tasks 配列に積まれる")
    func addTaskMultiple() {
        let saveURL = Self.tempSaveURL()
        defer { try? FileManager.default.removeItem(at: saveURL) }

        let state = AppState(saveURL: saveURL)
        state.addTask(title: "T1", body: "a")
        state.addTask(title: "T2", body: "b")
        state.addTask(title: "T3", body: "c")

        #expect(state.tasks.count == 3)
        #expect(state.tasks(in: .planning).count == 3)
    }

    // MARK: - moveTask

    @Test("moveTask: 有効な遷移で status が変わる")
    func moveTaskValidTransition() {
        let saveURL = Self.tempSaveURL()
        defer { try? FileManager.default.removeItem(at: saveURL) }

        let state = AppState(saveURL: saveURL)
        state.addTask(title: "T1", body: "x")
        let id = state.tasks[0].id
        let originalUpdate = state.tasks[0].updatedAt

        // 微小時間進めて updatedAt の変化を検出できるようにする
        Thread.sleep(forTimeInterval: 0.01)

        state.moveTask(id: id, to: .inProgress)

        #expect(state.tasks[0].status == .inProgress)
        #expect(state.tasks[0].updatedAt > originalUpdate)
    }

    @Test("moveTask: 無効な遷移 (planning → done) は無視される")
    func moveTaskInvalidTransitionIgnored() {
        let saveURL = Self.tempSaveURL()
        defer { try? FileManager.default.removeItem(at: saveURL) }

        let state = AppState(saveURL: saveURL)
        state.addTask(title: "T1", body: "x")
        let id = state.tasks[0].id

        state.moveTask(id: id, to: .done)

        #expect(state.tasks[0].status == .planning, "planning → done は canTransition で弾かれるはず")
    }

    @Test("moveTask: 存在しない id は no-op")
    func moveTaskUnknownID() {
        let saveURL = Self.tempSaveURL()
        defer { try? FileManager.default.removeItem(at: saveURL) }

        let state = AppState(saveURL: saveURL)
        state.addTask(title: "T1", body: "x")

        state.moveTask(id: UUID(), to: .inProgress)  // 別 id

        #expect(state.tasks[0].status == .planning)
    }

    // MARK: - deleteTask

    @Test("deleteTask: 指定タスクが消える + selectedTaskID もクリア")
    func deleteTaskClearsSelection() async {
        let saveURL = Self.tempSaveURL()
        defer { try? FileManager.default.removeItem(at: saveURL) }

        let state = AppState(saveURL: saveURL)
        state.addTask(title: "T1", body: "x")
        let id = state.tasks[0].id
        state.selectedTaskID = id

        // planning ステージ = worktree 未作成 + surface 無し。async 化後も
        // performCleanup は no-op で素通りするため、tasks 除去と
        // selectedTaskID クリアのみ検証する (wt 非依存)。
        await state.deleteTask(id: id)

        #expect(state.tasks.isEmpty)
        #expect(state.selectedTaskID == nil)
    }

    // MARK: - Persistence

    @Test("persistence: save → reload で tasks が再現される")
    func persistenceRoundTrip() async throws {
        let saveURL = Self.tempSaveURL()
        defer { try? FileManager.default.removeItem(at: saveURL) }

        // 1 つ目の AppState でタスク追加・遷移
        do {
            let s1 = AppState(saveURL: saveURL)
            s1.addTask(title: "Keep me", body: "please")
            s1.addTask(title: "Move me", body: "to in progress")
            let moveID = s1.tasks.first(where: { $0.title == "Move me" })!.id
            s1.moveTask(id: moveID, to: .inProgress)
        }

        // 2 つ目の AppState で同じ saveURL を読む
        let s2 = AppState(saveURL: saveURL)
        #expect(s2.tasks.count == 2)

        let reloadedKeep = s2.tasks.first(where: { $0.title == "Keep me" })
        #expect(reloadedKeep?.status == .planning)

        let reloadedMove = s2.tasks.first(where: { $0.title == "Move me" })
        #expect(reloadedMove?.status == .inProgress)
    }

    @Test("persistence: ファイルが無い初回起動は空配列")
    func persistenceEmptyStart() {
        let saveURL = Self.tempSaveURL()
        defer { try? FileManager.default.removeItem(at: saveURL) }

        let state = AppState(saveURL: saveURL)
        #expect(state.tasks.isEmpty)
    }
}
