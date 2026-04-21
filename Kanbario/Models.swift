import Foundation
import CoreTransferable
import SwiftUI

// MARK: - TaskCard

/// カンバンの 1 カード。Claude セッション 1 つと worktree 1 つに対応する。
/// Swift 標準の `Task` (concurrency) と名前衝突を避けるため `TaskCard` にしている。
///
/// LLM メタフィールド (tag / risk / promptV / evalScore / owner / runs / fails /
/// cost / pr / mergedAt / humanReview / regressions / needs) は Claude Design の
/// Kanban Wireframes に由来。カード UI のステージ別情報量を埋めるため optional で
/// 追加している。Codable の標準挙動により nil で JSON に出ない + 既存 state.json
/// (v1) はそのままデコードできる。
struct TaskCard: Identifiable, Codable, Hashable {
    let id: UUID
    var projectID: UUID
    var title: String
    var body: String           // Start 時に claude の初回プロンプトとして渡される
    var status: TaskStatus
    var branch: String         // "kanbario/<uuid>"
    var createdAt: Date
    var updatedAt: Date

    // ─── LLM メタ (wireframe 由来、すべて optional) ──────────────────────────
    /// 機能カテゴリ (RAG / Agent / Extract 等)。カードヘッダの色付きピル。
    var tag: LLMTag?
    /// リスク。カード右上の三角バッジ。
    var risk: RiskLevel?
    /// プロンプト版。カード左下の mono 表示 ("v0.3" 等)。
    var promptV: String?
    /// eval スコア 0..1。カード内円グラフ + terminal メタストリップ。
    var evalScore: Double?
    /// 担当者の 1 文字 ("J", "M" 等)。カード左下のアバター。
    var owner: String?
    /// 実行回数 / 失敗数 / 1 呼び出しあたりコスト (in progress ステージ)。
    var runs: Int?
    var fails: Int?
    var cost: Double?
    /// Review ステージ: 人手レビュー進捗 ("74%" 等) と regression 件数。
    var humanReview: String?
    var regressions: Int?
    /// Done ステージ: マージ済 PR 番号と相対時刻 ("#461", "2d ago")。
    var pr: String?
    var mergedAt: String?
    /// Planning ステージ: 足りない前提のチップ群 ("golden set", "PII review" 等)。
    var needs: [String]?
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

    /// デザイン wireframe のカラムヘッダ下の 1 行 hint ("scope + prompts drafted" 等)。
    var hint: String {
        switch self {
        case .planning:   return "scope + prompts drafted"
        case .inProgress: return "building / iterating"
        case .review:     return "eval + human review"
        case .done:       return "merged / shipped"
        }
    }

    /// カラムのドット/アクセントカラー。wireframe の dot カラーに揃えている。
    var dotColor: Color {
        switch self {
        case .planning:   return Color(red: 0x5e/255, green: 0x5c/255, blue: 0xe6/255)
        case .inProgress: return WF.warn
        case .review:     return WF.purple
        case .done:       return WF.done
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

// MARK: - LLMTag

/// wireframe の LLM_TAG_COLOR 辞書を Swift 化。
/// raw value は UI 表示文字列と兼用 (JSON には raw value 文字列で入る)。
enum LLMTag: String, Codable, CaseIterable, Hashable {
    case rag        = "RAG"
    case agent      = "Agent"
    case classifier = "Classifier"
    case extract    = "Extract"
    case summarize  = "Summarize"
    case chat       = "Chat"
    case toolUse    = "Tool-use"
    case eval       = "Eval"
    case infra      = "Infra"

    var color: Color {
        switch self {
        case .rag:        return Color(red: 0x0a/255, green: 0x84/255, blue: 0xff/255)
        case .agent:      return WF.purple
        case .classifier: return WF.done
        case .extract:    return WF.warn
        case .summarize:  return Color(red: 0x64/255, green: 0xd2/255, blue: 0xff/255)
        case .chat:       return WF.pink
        case .toolUse:    return Color(red: 0x5e/255, green: 0x5c/255, blue: 0xe6/255)
        case .eval:       return Color(red: 0x86/255, green: 0x86/255, blue: 0x8b/255)
        case .infra:      return WF.ink3
        }
    }
}

// MARK: - RiskLevel

/// wireframe の RiskBadge の 3 段階。Codable で "H"/"M"/"L" として保存。
enum RiskLevel: String, Codable, CaseIterable, Hashable {
    case low    = "L"
    case medium = "M"
    case high   = "H"

    var label: String {
        switch self {
        case .low:    return "Low risk"
        case .medium: return "Med risk"
        case .high:   return "High risk"
        }
    }

    var color: Color {
        switch self {
        case .low:    return WF.ink3
        case .medium: return WF.warn
        case .high:   return WF.pink
        }
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
