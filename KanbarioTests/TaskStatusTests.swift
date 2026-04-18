import Testing
@testable import Kanbario

struct TaskStatusTests {

    // MARK: - 許可される遷移

    @Test("planning → inProgress は許可")
    func allowsPlanningToInProgress() {
        #expect(TaskStatus.planning.canTransition(to: .inProgress))
    }

    @Test("inProgress → review は許可 (Claude exit hook)")
    func allowsInProgressToReview() {
        #expect(TaskStatus.inProgress.canTransition(to: .review))
    }

    @Test("review → done は許可 (cleanup 発火)")
    func allowsReviewToDone() {
        #expect(TaskStatus.review.canTransition(to: .done))
    }

    @Test("review → inProgress は許可 (再実行)")
    func allowsReviewToInProgress() {
        #expect(TaskStatus.review.canTransition(to: .inProgress))
    }

    // MARK: - 禁止される遷移 (確定している重要ケース)

    @Test("planning → review は禁止 (Claude を通さずに review は不自然)")
    func blocksPlanningToReview() {
        #expect(!TaskStatus.planning.canTransition(to: .review))
    }

    @Test("planning → done は禁止 (何もせず done は意味不明)")
    func blocksPlanningToDone() {
        #expect(!TaskStatus.planning.canTransition(to: .done))
    }

    @Test("inProgress → done は禁止 (review を経由すべき)")
    func blocksInProgressToDone() {
        #expect(!TaskStatus.inProgress.canTransition(to: .done))
    }

    @Test("inProgress → planning は禁止 (後戻りさせない)")
    func blocksInProgressToPlanning() {
        #expect(!TaskStatus.inProgress.canTransition(to: .planning))
    }

    @Test("done → * は全て禁止 (done は終端状態)")
    func doneIsTerminal() {
        #expect(!TaskStatus.done.canTransition(to: .planning))
        #expect(!TaskStatus.done.canTransition(to: .inProgress))
        #expect(!TaskStatus.done.canTransition(to: .review))
    }

    // MARK: - 同じ状態への遷移 (設計判断: 現状は禁止)

    @Test("self == next は禁止 (現状)")
    func blocksSameState() {
        for s in TaskStatus.allCases {
            #expect(!s.canTransition(to: s), "\(s) → \(s) は現状禁止")
        }
    }

    // MARK: - 網羅チェック (将来 case 追加時に testing 側も見直すアラーム)

    @Test("TaskStatus.allCases は 4 つ (planning/inProgress/review/done)")
    func statusCountInvariant() {
        #expect(TaskStatus.allCases.count == 4)
    }
}
