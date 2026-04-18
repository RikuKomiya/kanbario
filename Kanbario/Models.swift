import Foundation

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

// MARK: - Project

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var repoPath: String
    var defaultBranch: String
    var createdAt: Date
}
