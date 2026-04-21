import SwiftUI
import CoreGraphics
import UniformTypeIdentifiers

// Claude Design の Kanban Wireframes (mvp-board.jsx) を SwiftUI に移植したボード。
// 紙色背景 + sketchy 黒枠 + 手書きフォントで wireframe 言語を踏襲している。
// 既存の Drag&Drop state machine (canTransition) と ActivityBadge は温存。

// MARK: - Board root

/// Kanban ボード本体。Chrome + ヘッダ + 4 カラムグリッド。
struct KanbanBoardView: View {
    @Environment(AppState.self) private var appState
    /// 親 (ContentView) から渡される「新規タスクを開く」アクション。
    /// wireframe の "New task" ボタン & Planning 列の `+ Add task` カードから発火する。
    var onNewTask: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chrome
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(WF.paper)
                .overlay(Divider().background(WF.line).opacity(0.35), alignment: .bottom)

            header
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 10)

            columnsGrid
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WF.paper)
    }

    // MARK: - Chrome (breadcrumb + state pills + avatar stack)

    /// wireframe 最上段: sidebar アイコン + ブレッドクラム + 状態ピル + アバタースタック。
    /// NSWindow の本物の信号ボタンはタイトルバーに存在するため、ここでは再描画しない
    /// (HTML 版の 3 色ドットは standalone `.html` 用の飾りで macOS では重複になる)。
    private var chrome: some View {
        HStack(spacing: 12) {
            WFIcon.sidebar()
            Hand("AI features  /  ", size: 16, color: WF.ink2)
            Hand(projectName, size: 16)
            Spacer()

            // 状態ピル (ship 済 / in progress 件数)
            WFPill(color: WF.done) {
                WFDot(color: WF.done, size: 6)
                Text("\(shippedCount) shipped")
            }
            WFPill(color: WF.warn) {
                WFDot(color: WF.warn, size: 6)
                Text("\(inProgressCount) in progress")
            }

            // Owner avatar スタック。owner 設定済タスクから distinct な initial を集める。
            avatarStack
        }
    }

    private var projectName: String {
        if appState.repoPath.isEmpty { return appState.defaultProject.name }
        return (appState.repoPath as NSString).lastPathComponent
    }

    private var shippedCount: Int { appState.tasks(in: .done).count }
    private var inProgressCount: Int { appState.tasks(in: .inProgress).count }

    private var avatarStack: some View {
        let initials = Array(Set(appState.tasks.compactMap { $0.owner?.prefix(1).uppercased() })).sorted()
        return HStack(spacing: -6) {
            ForEach(Array(initials.prefix(5)), id: \.self) { initial in
                WFAvatar(initial: initial, size: 24)
            }
        }
    }

    // MARK: - Header (title + squiggle + search + new task)

    private var header: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Hand("LLM MVP board", size: 26, weight: .bold)
                Squiggle(width: 120)
            }
            Hand("tap any card → open shell in modal", size: 12, color: WF.ink3)
                .padding(.bottom, 4)

            Spacer()

            // 検索ピル (wireframe 準拠、UI のみで機能は未実装)
            HStack(spacing: 6) {
                WFIcon.search()
                Hand("search…", size: 13, color: WF.ink3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: 8).stroke(WF.line, lineWidth: 1.2)
            )

            // New task ボタン (黒塗り + 白文字、wireframe の強調スタイル)
            Button(action: onNewTask) {
                HStack(spacing: 6) {
                    WFIcon.plus(color: WF.paper)
                    Hand("New task", size: 13, color: WF.paper)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(WF.ink, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    // MARK: - Columns grid

    private var columnsGrid: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                KanbanColumn(
                    status: status,
                    tasks: appState.tasks(in: status),
                    onAddTask: onNewTask
                )
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Column

/// 1 列分の View。ドット + ラベル + 件数 + (Planning のみ +)、hint、カード列、
/// Planning 末尾の破線プレースホルダ (wireframe の `+ Add task`)。
struct KanbanColumn: View {
    @Environment(AppState.self) private var appState
    let status: TaskStatus
    let tasks: [TaskCard]
    var onAddTask: () -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader
                .padding(.horizontal, 4)
                .padding(.top, 2)
                .padding(.bottom, 8)

            Hand(status.hint, size: 11, color: WF.ink3)
                .padding(.horizontal, 4)
                .padding(.bottom, 10)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(tasks) { task in
                        taskRow(task)
                    }
                    // 別列から drag 中の「ここに落ちるよ」プレビュー。
                    if let dragging = appState.draggingTask,
                       dragging.status != status,
                       isTargeted {
                        DropPlaceholderCard(task: dragging, accent: status.dotColor)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                    // Planning 列末尾の破線プレースホルダ (wireframe で顕著なアフォーダンス)。
                    if status == .planning {
                        addTaskDashedCard
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDrop(of: [.utf8PlainText], delegate: KanbanColumnDropDelegate(
            status: status,
            appState: appState,
            isTargeted: $isTargeted
        ))
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        .animation(.easeInOut(duration: 0.15), value: appState.draggingTaskID)
    }

    // MARK: - Header row

    private var columnHeader: some View {
        HStack(spacing: 8) {
            WFDot(color: status.dotColor, size: 9)
            Hand(status.displayName, size: 16, weight: .bold)
            Text(String(format: "%02d", tasks.count))
                .font(WFFont.mono(11))
                .foregroundStyle(WF.ink3)
            Spacer()
            if status == .planning {
                Button(action: onAddTask) {
                    WFIcon.plus()
                }
                .buttonStyle(.plain)
                .help("New task (⌘N)")
            }
        }
    }

    // MARK: - Task row with drag

    @ViewBuilder
    private func taskRow(_ task: TaskCard) -> some View {
        Button {
            appState.selectedTaskID = task.id
        } label: {
            MVPCard(
                task: task,
                stage: status,
                activity: appState.activitiesByTaskID[task.id],
                isSelected: appState.selectedTaskID == task.id
            )
        }
        .buttonStyle(.plain)
        .opacity(appState.draggingTaskID == task.id ? 0 : 1)
        // drag 実装は既存の KanbanBoardView と同じ。preview closure は渡さず
        // OS default snapshot に任せる (kanban-code 方式、過去 commit 参照)。
        .onDrag {
            let id = task.id
            appState.draggingTaskID = id
            Task { @MainActor in
                while appState.draggingTaskID == id {
                    let pressed = CGEventSource.buttonState(.combinedSessionState, button: .left)
                    if !pressed {
                        appState.draggingTaskID = nil
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
            return NSItemProvider(object: id.uuidString as NSString)
        }
        .transition(.identity)
    }

    // MARK: - Planning dashed placeholder

    private var addTaskDashedCard: some View {
        Button(action: onAddTask) {
            HStack(spacing: 6) {
                WFIcon.plus(color: WF.ink3)
                Hand("Add task", size: 12, color: WF.ink3)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(WF.ink3, style: StrokeStyle(lineWidth: 1.4, dash: [5, 3]))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - MVPCard (per-stage content)

/// ステージに応じて表示情報が切り替わるカード。wireframe の mvp-board.jsx MVPCard 踏襲。
struct MVPCard: View {
    let task: TaskCard
    let stage: TaskStatus
    var activity: ClaudeActivity? = nil
    var isSelected: Bool = false

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            topRow
            Hand(task.title, size: 14, weight: .bold)

            if task.promptV != nil || !task.branch.isEmpty {
                promptBranchRow
            }

            stageBlock

            Divider()
                .overlay(WF.ink3.opacity(0.35))

            footerRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sketchBox(radius: 10, shadow: true)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? WF.accent : .clear, lineWidth: 2)
        )
        .shadow(color: isHovering ? WF.cardShadow.opacity(1.5) : WF.cardShadow,
                radius: 0, x: 2, y: isHovering ? 4 : 3)
        .scaleEffect(isHovering ? 1.008 : 1.0)
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.15), value: isHovering)
    }

    // MARK: - Sub-rows

    private var topRow: some View {
        HStack(alignment: .center, spacing: 6) {
            if let tag = task.tag {
                LLMTagPill(tag: tag)
            } else {
                // 未設定時は薄い placeholder ピル
                WFPill(color: WF.ink3) { Text("untagged") }
            }
            Spacer()
            if let activity { ActivityBadge(activity: activity) }
            if let risk = task.risk { RiskBadge(risk: risk) }
        }
    }

    private var promptBranchRow: some View {
        HStack(spacing: 6) {
            if let promptV = task.promptV {
                Text("prompt").font(WFFont.mono(10)).foregroundStyle(WF.ink3)
                Text(promptV).font(WFFont.mono(10)).foregroundStyle(WF.ink2)
            }
            if task.promptV != nil && !task.branch.isEmpty {
                Text("·").font(WFFont.mono(10)).foregroundStyle(WF.ink3)
            }
            if !task.branch.isEmpty {
                Text(task.branch.replacingOccurrences(of: "kanbario/", with: ""))
                    .font(WFFont.mono(10))
                    .foregroundStyle(WF.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    // MARK: - Stage-specific block

    @ViewBuilder
    private var stageBlock: some View {
        switch stage {
        case .planning:
            if let needs = task.needs, !needs.isEmpty {
                FlowHStack(spacing: 4, rowSpacing: 4) {
                    ForEach(needs, id: \.self) { n in
                        WFPill(color: WF.ink3) { Text(n) }
                    }
                }
            }
        case .inProgress:
            if let eval = task.evalScore {
                HStack(spacing: 14) {
                    EvalMeter(score: eval, size: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        if let runs = task.runs, let fails = task.fails {
                            Metric(label: "runs / fails", value: "\(runs) / \(fails)")
                        }
                        if let cost = task.cost {
                            Metric(label: "cost / call", value: String(format: "$%.3f", cost))
                        }
                    }
                    Spacer()
                }
            }
        case .review:
            if let eval = task.evalScore {
                HStack(spacing: 14) {
                    EvalMeter(score: eval, size: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        if let hr = task.humanReview {
                            Metric(label: "human review", value: hr)
                        }
                        if let r = task.regressions {
                            Metric(label: "regressions", value: String(r),
                                   color: r > 0 ? WF.pink : WF.ink)
                        }
                    }
                    Spacer()
                }
            }
        case .done:
            HStack(spacing: 14) {
                EvalMeter(score: task.evalScore, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    if let pr = task.pr {
                        Metric(label: "PR", value: pr, color: WF.accent)
                    }
                    if let merged = task.mergedAt {
                        Metric(label: "merged", value: merged)
                    }
                }
                Spacer()
            }
        }
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            WFAvatar(initial: task.owner ?? "?", size: 20,
                     bg: task.owner == nil ? WF.paperAlt : WF.accentSoft,
                     color: task.owner == nil ? WF.ink3 : WF.accent)
            Hand("owner", size: 11, color: WF.ink3)
            Spacer()
            HStack(spacing: 4) {
                WFIcon.openShell(color: WF.ink2)
                Hand("open shell", size: 10, color: WF.ink2)
            }
        }
    }
}

// MARK: - DropPlaceholder

/// 別列から drag 中に挿入される半透明プレースホルダ。
struct DropPlaceholderCard: View {
    let task: TaskCard
    let accent: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Rectangle()
                .fill(accent)
                .frame(width: 3)
                .clipShape(Capsule())
            Hand(task.title, size: 13, color: WF.ink2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(accent.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accent.opacity(0.55),
                              style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        )
        .opacity(0.8)
    }
}

// MARK: - Drop delegate (unchanged semantics)

/// 列ごとの drop handler。UI theme だけ差し替わり、遷移判定ロジックは旧実装と同じ。
struct KanbanColumnDropDelegate: DropDelegate {
    let status: TaskStatus
    let appState: AppState
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let id = appState.draggingTaskID,
              let current = appState.tasks.first(where: { $0.id == id })?.status
        else {
            return DropProposal(operation: .forbidden)
        }
        if current == status { return DropProposal(operation: .move) }
        return current.canTransition(to: status)
            ? DropProposal(operation: .move)
            : DropProposal(operation: .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            appState.draggingTaskID = nil
            isTargeted = false
        }
        guard let id = appState.draggingTaskID else { return false }
        appState.moveTask(id: id, to: status)
        return true
    }
}

// MARK: - ActivityBadge (kept from prior implementation)

/// カード右上の claude 実時間バッジ。wireframe 本体には存在しないが、hook event を
/// 可視化するため kanbario 独自に維持している (過去 PR #4 参照)。
struct ActivityBadge: View {
    let activity: ClaudeActivity

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(WFFont.hand(10, weight: .bold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    private var icon: String {
        switch activity {
        case .running:    return "bolt.fill"
        case .needsInput: return "person.wave.2.fill"
        }
    }
    private var label: String {
        switch activity {
        case .running:    return "Working"
        case .needsInput: return "Your turn"
        }
    }
    private var color: Color {
        switch activity {
        case .running:    return .blue
        case .needsInput: return .orange
        }
    }
}

// MARK: - Flow HStack (simple wrapping row)

/// `needs` チップ群を折り返し配置するミニレイアウト。SwiftUI には flex-wrap が
/// ないので、GeometryReader で width を測って手で改行する。軽量用途のみ。
struct FlowHStack<Content: View>: View {
    var spacing: CGFloat = 4
    var rowSpacing: CGFloat = 4
    @ViewBuilder var content: () -> Content

    var body: some View {
        // SwiftUI 5 の Layout を使う簡易実装。過剰実装を避け、標準 HStack を
        // 折り返したい時の近似として `.frame(maxWidth: .infinity, alignment: .leading)`
        // + `Wrap` Layout を代用する。
        WrapLayout(spacing: spacing, rowSpacing: rowSpacing) {
            content()
        }
    }
}

/// 横並び → はみ出したら次行、というだけの Layout。
struct WrapLayout: Layout {
    var spacing: CGFloat = 4
    var rowSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW && x > 0 {
                y += rowH + rowSpacing
                x = 0; rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxX = max(maxX, x)
        }
        return CGSize(width: maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x - bounds.minX + s.width > maxW && x > bounds.minX {
                y += rowH + rowSpacing
                x = bounds.minX
                rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
