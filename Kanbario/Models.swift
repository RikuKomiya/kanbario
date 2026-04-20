import Foundation
import CoreTransferable

// MARK: - TaskCard

/// カンバンの 1 カード。Claude セッション 1 つと worktree 1 つに対応する。
/// Swift 標準の `Task` (concurrency) と名前衝突を避けるため `TaskCard` にしている。
struct TaskCard: Identifiable, Codable, Hashable {
    let id: UUID
    var projectID: UUID
    var title: String
    var body: String           // Start 時に claude の初回プロンプトとして渡される
    var status: TaskStatus
    var branch: String         // "kanbario/<uuid>"
    var createdAt: Date
    var updatedAt: Date
}

// MARK: - TaskStatus

/// Kanban ボードの 4 列。
enum TaskStatus: String, CaseIterable, Codable {
    case planning
    case inProgress = "in_progress"
    case review
    case done

    var displayName: String {
        switch self {
        case .planning:   return "Planning"
        case .inProgress: return "In Progress"
        case .review:     return "Review"
        case .done:       return "Done"
        }
    }

    /// `self` から `next` への遷移が許可されているかを返す。
    /// KanbanBoardView の drag-and-drop でここを enforce する。
    /// 仕様: docs/spec.md §1.2、確定した遷移は以下の 4 つのみ。
    /// - planning → inProgress (Start ボタン)
    /// - inProgress → review (Claude exit hook)
    /// - review → done (ユーザー手動、cleanup 発火)
    /// - review → inProgress (「もう一度やらせる」)
    func canTransition(to next: TaskStatus) -> Bool {
        if self == .planning && next == .inProgress { return true }
        if self == .inProgress && next == .review { return true }
        if self == .review && next == .done { return true }
        if self == .review && next == .inProgress { return true }
        return false
    }
}

// MARK: - ClaudeActivity

/// 詳細画面のバッジ表現に使う、claude セッションの即時状態。
/// hook event を受けて AppState.activitiesByTaskID にだけ載せる
/// (TaskCard には永続化しない — process が死ねば意味がないので)。
enum ClaudeActivity: String {
    case running     // tool 実行中 / prompt 受領直後
    case needsInput  // Stop hook = ターン終了、ユーザー入力待ち
}

// MARK: - Project

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var repoPath: String
    var defaultBranch: String
    var createdAt: Date
}

// MARK: - Drag payload

/// Drag-and-drop のペイロード。TaskCard 全体を運ぶと大きすぎるので ID だけ。
/// drop 先で AppState から本体を引き直す。
///
/// 実装メモ: 最初は独自 UTType `app.kanbario.task-drag` + CodableRepresentation で書いたが、
/// カスタム UTType は Info.plist の UTExportedTypeDeclarations に登録しないと pasteboard
/// が認識せず、同一プロセス内ドロップでも silent fail する。Info.plist いじりを避けるため、
/// String (標準 Transferable) 経由の ProxyRepresentation に切り替えた。
struct TaskDrag: Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(
            exporting: { (drag: TaskDrag) in drag.id.uuidString },
            importing: { (s: String) in TaskDrag(id: UUID(uuidString: s) ?? UUID()) }
        )
    }
}
