import SwiftUI
import AppKit  // NSPasteboard (Copy title/prompt/branch の contextMenu で使用)
import CoreGraphics
import UniformTypeIdentifiers
import Combine  // ElapsedTimer の Timer.publish(...).autoconnect() で必要

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
                permissionMessage: appState.pendingPermissionByTaskID[task.id],
                isStarting: appState.startProgressByTaskID[task.id] != nil,
                isResuming: appState.resumingTaskIDs.contains(task.id),
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
    @Environment(AppState.self) private var appState
    let task: TaskCard
    let stage: TaskStatus
    var activity: ClaudeActivity? = nil
    /// Claude Code が tool permission / approval を求めている時のメッセージ。
    /// 非 nil の間は ActivityBadge を置き換えて PermissionBadge を表示する
    /// (permission は緊急度が高いので上書き優先)。
    var permissionMessage: String? = nil
    /// drag で planning → inProgress に落としたタスクが wt create / hook 実行
    /// 中 (startProgressByTaskID に entry がある) の間 true。StartingBadge を
    /// 出してユーザーに「動いている」ことを示す。完了したら inProgress 列に
    /// 自動で移動する。
    var isStarting: Bool = false
    /// アプリ起動時の自動 resume / 詳細モーダルを開いた直後の resume が走って
    /// いる間 true。ResumingBadge で「claude --continue 起動中」を示す。
    /// `isStarting` (新規 start) と排他的な意味を持つので表示も優先順で分岐。
    var isResuming: Bool = false
    var isSelected: Bool = false

    @State private var isHovering = false

    private var isDeleting: Bool {
        appState.deletingTaskIDs.contains(task.id)
    }

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
        // 削除処理中はカード全体を視覚的に薄く落として「消える予定」を
        // 示す。click は引き続き可能にして取り消し操作 (Detail 表示中に
        // alert をキャンセル) が妨げられないよう hit-test は残す。
        .opacity(isDeleting ? 0.45 : 1)
        // 右クリックでカード内容を pasteboard にコピー + 削除。
        // title / prompt / branch の 3 つを用意しておけば大抵の「引き継ぎ」
        // 「別タスクで再利用」に対応できる。Delete は dirty worktree の時
        // だけ確認 alert が出る (AppState.requestDelete 経由)。
        .contextMenu {
            Button("Copy title") {
                MVPCard.copy(task.title)
            }
            Button("Copy prompt") {
                MVPCard.copy(task.body)
            }
            Button("Copy branch") {
                MVPCard.copy(task.branch)
            }
            Divider()
            Button("Delete task", role: .destructive) {
                Task { await appState.requestDelete(id: task.id) }
            }
            .disabled(isDeleting)
        }
    }

    /// `NSPasteboard.general` に string を書き込むだけの薄いヘルパー。
    /// clearContents() を先に呼ばないと以前の内容と混ざるので注意。
    fileprivate static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
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
            // 優先順: starting > resuming > permission > activity。
            // Starting / Resuming 中は permission / activity どちらも意味を
            // なさないので 1 つだけに集約して視線を分散させない。
            // starting と resuming の排他: 新規 start と既存 claude の継続は
            // 同時発生し得ないので、start 優先 (起動直後は resuming 判定を
            // 読み取っている短時間だけ)。
            if isStarting {
                StartingBadge()
            } else if isResuming {
                ResumingBadge()
            } else if let permissionMessage {
                PermissionBadge(message: permissionMessage)
            } else if let activity {
                ActivityBadge(activity: activity)
            }
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
                Text(task.displayBranch)
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
            VStack(alignment: .leading, spacing: 8) {
                if let needs = task.needs, !needs.isEmpty {
                    FlowHStack(spacing: 4, rowSpacing: 4) {
                        ForEach(needs, id: \.self) { n in
                            WFPill(color: WF.ink3) { Text(n) }
                        }
                    }
                }
                // カードから直接 Start を走らせるボタン。モーダルを開かずに
                // 裏で wt create + claude spawn を走らせたい時の入口。drag
                // と同じ AppState.startTask を呼ぶので挙動は完全一致する
                // (spinner / StartingBadge / 完了時の列移動まで自動で連動)。
                planningStartButton
            }
        case .inProgress:
            VStack(alignment: .leading, spacing: 8) {
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
                ActivityPanel(taskID: task.id)
                LiveLogView(taskID: task.id)
            }
        case .review, .qa:
            // QA は review と同じカード中身 (claude のライブ状態 + eval /
            // human review / regressions)。「QA 中のカードを見ても何が
            // 起きているか分かる」ことが UI 整理カラムの価値なので、情報量は
            // 落とさない。
            VStack(alignment: .leading, spacing: 8) {
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
                ActivityPanel(taskID: task.id)
                LiveLogView(taskID: task.id)
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

    /// planning カード専用の Start ボタン。外側の taskRow が Button で包んで
    /// selectedTaskID をセットしているので、このボタンは `.buttonStyle(.plain)`
    /// で hit-test を自分側に持って外側の tap を consume する (SwiftUI の
    /// Button-in-Button は内側優先なので、これでモーダルを開かずに start
    /// 処理だけ走らせられる)。
    ///
    /// 起動判定は TaskDetailView.planningBody と同じ — repo 未設定 or 既に
    /// surface がある場合は disable。isStarting は親から渡される
    /// startProgressByTaskID 由来の flag で、裏走行中は spinner + 「Starting…」
    /// に切り替わり、完了 (= inProgress 列に自動移動) と同時に消える。
    @ViewBuilder
    private var planningStartButton: some View {
        let hasSurface = appState.activeSurfaces[task.id] != nil
        let canStart = appState.canStartTasks && !isStarting && !hasSurface
        HStack(spacing: 6) {
            Button {
                Task { await appState.startTask(task) }
            } label: {
                HStack(spacing: 4) {
                    if isStarting {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.55)
                            .frame(width: 10, height: 10)
                        Hand("Starting…", size: 11, color: WF.ink2)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(canStart ? WF.paper : WF.ink3)
                        Hand("Start", size: 11,
                             color: canStart ? WF.paper : WF.ink3)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(
                    Capsule().fill(
                        isStarting ? Color.clear
                        : (canStart ? WF.ink : WF.ink3.opacity(0.25))
                    )
                )
                .overlay(
                    Capsule().stroke(
                        isStarting ? WF.ink3 : Color.clear,
                        lineWidth: 1
                    )
                )
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
            .help(startHelpText)

            // Starting 中だけ出す Cancel ボタン。hook (post-switch /
            // post-start) が長引いて進まない時の救済手段 — タップすると
            // AppState.cancelStart → WorktreeService.run の onCancel で
            // subprocess に SIGTERM が飛び、planning に戻る。
            if isStarting {
                Button {
                    appState.cancelStart(id: task.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(WF.pink.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("キャンセル (wt / hook を中断して planning に戻す)")
            }

            Spacer()

            // Start 中は wt / hook の最新進捗行を小さく出す。inProgress に
            // 飛んだ後は LiveLogView が引き継ぐので、ここは「起動する数秒」
            // だけのフィードバック。
            if let progress = appState.startProgressByTaskID[task.id] {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 9))
                        .foregroundStyle(WF.ink3)
                    Text(progress)
                        .font(WFFont.mono(9))
                        .foregroundStyle(WF.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var startHelpText: String {
        if !appState.canStartTasks { return "Repo を選んでください (toolbar)" }
        if appState.activeSurfaces[task.id] != nil { return "既に起動済" }
        if isStarting { return "起動中…" }
        return "Start Claude (裏で wt switch + claude 起動)"
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

// MARK: - PermissionBadge

/// Claude Code が tool permission / approval を要求している時にカード右上に
/// 出す目立つバッジ。色は WF.pink (危険色) で、形は Capsule。詳細 message は
/// hover tooltip で展開する (狭いカード内に長文を載せない設計)。
///
/// kanbario 自体は y/n を送る経路を持たないので、このバッジの役割は純粋に
/// 「気づかせる」こと。ユーザーはバッジを見て該当タスクを開き、terminal 内で
/// 承認する。
struct PermissionBadge: View {
    let message: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 9, weight: .bold))
            Text("Permission")
                .font(WFFont.hand(10, weight: .bold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(WF.pink.opacity(0.18))
        .foregroundStyle(WF.pink)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(WF.pink.opacity(0.55), lineWidth: 1))
        .help(message)
    }
}

// MARK: - StartingBadge

/// drag で planning → inProgress に落とした直後、wt create + post-start hook
/// が走っている間カード右上に出す「動いている感」バッジ。completion すると
/// startProgressByTaskID から entry が消えて自動的にカードが inProgress 列に
/// 移動する (= バッジは消える)。spinner 付きで非同期 work を視覚化。
struct StartingBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.6)
                .frame(width: 10, height: 10)
            Text("Starting")
                .font(WFFont.hand(10, weight: .bold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(WF.warn.opacity(0.18))
        .foregroundStyle(WF.warn)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(WF.warn.opacity(0.55), lineWidth: 1))
    }
}

// MARK: - ResumingBadge

/// アプリ起動時の auto-resume や、詳細モーダルを開いた直後の `claude --continue`
/// 起動中にカード右上に出す青系バッジ。StartingBadge (オレンジ = 新規 start)
/// と色で区別し、「再開中」と意味が伝わる手話号 (arrow.clockwise) にする。
/// Resume は概ね 2〜5 秒で完了するので、完了と同時に自然消滅する短命バッジ。
struct ResumingBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.6)
                .frame(width: 10, height: 10)
            Text("Resuming")
                .font(WFFont.hand(10, weight: .bold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(WF.accent.opacity(0.18))
        .foregroundStyle(WF.accent)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(WF.accent.opacity(0.55), lineWidth: 1))
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

// MARK: - ActivityPanel

/// カード上で Claude の「今動いている感」を表示する。Claude Code のターミナル
/// UI にある以下の要素を縮約再現:
///   - 現在実行中の tool 名と引数 (+ spinner): `→ Fetch(https://...)`
///   - TodoWrite で登録された現在進行中タスクと経過時間: `✳ Investigate… (1m 26s)`
///   - TodoWrite 全体の chip リスト: `◼ done · ▸ doing · ◻ pending`
///
/// AppState.currentActivityByTaskID を source of truth にするので、tailer が
/// transcript から拾った新情報は即描画される (Observable の auto-propagation)。
struct ActivityPanel: View {
    @Environment(AppState.self) private var appState
    let taskID: UUID

    var body: some View {
        let permission = appState.pendingPermissionByTaskID[taskID]
        let activity = appState.currentActivityByTaskID[taskID]
        if permission != nil || (activity.map { hasContent($0) } ?? false) {
            VStack(alignment: .leading, spacing: 4) {
                if let permission {
                    permissionRow(message: permission)
                }
                if let a = activity {
                    if let tool = a.activeToolName {
                        runningToolRow(name: tool,
                                       inputSummary: a.activeToolInputSummary)
                    }
                    if let current = a.todos.first(where: { $0.status == "in_progress" }) {
                        currentTodoRow(todo: current,
                                       startedAt: a.turnStartedAt)
                    }
                    if !a.todos.isEmpty {
                        todoListRow(todos: a.todos)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(WF.paperAlt, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(permission != nil ? WF.pink.opacity(0.45) : WF.ink3.opacity(0.3),
                            lineWidth: permission != nil ? 1.2 : 0.8)
            )
        }
    }

    private func hasContent(_ a: CurrentActivity) -> Bool {
        a.activeToolName != nil || !a.todos.isEmpty
    }

    /// permission message を 1 行 bold + pink で強調表示。hover で全文 tooltip。
    @ViewBuilder
    private func permissionRow(message: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(WF.pink)
            Text(message)
                .font(WFFont.mono(10))
                .fontWeight(.bold)
                .foregroundStyle(WF.pink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .help(message)
    }

    /// 実行中 tool 行。spinner (小さな Claude Code 風 ⎿) + tool 名 + 引数サマリ。
    @ViewBuilder
    private func runningToolRow(name: String, inputSummary: String?) -> some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.6)
                .frame(width: 10, height: 10)
            Text(name)
                .font(WFFont.mono(10))
                .fontWeight(.bold)
                .foregroundStyle(WF.warn)
            if let s = inputSummary {
                Text(s)
                    .font(WFFont.mono(10))
                    .foregroundStyle(WF.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    /// 現在進行中 todo 行。Claude Code の `✳ Investigate… (1m 26s)` を模倣。
    @ViewBuilder
    private func currentTodoRow(todo: TodoItem, startedAt: Date?) -> some View {
        HStack(spacing: 4) {
            Text("✳")
                .font(.system(size: 10))
                .foregroundStyle(WF.accent)
            Text(todo.activeForm ?? todo.content)
                .font(WFFont.mono(10))
                .fontWeight(.bold)
                .foregroundStyle(WF.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            if let startedAt {
                ElapsedTimer(startedAt: startedAt)
            }
            Spacer()
        }
    }

    /// TodoWrite 全体の進捗表示。done count と最大 4 件の head list。
    @ViewBuilder
    private func todoListRow(todos: [TodoItem]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(todos.prefix(5).indices, id: \.self) { i in
                let t = todos[i]
                HStack(spacing: 4) {
                    Text(Self.mark(for: t.status))
                        .font(WFFont.mono(9))
                        .foregroundStyle(Self.color(for: t.status))
                    Text(t.content)
                        .font(WFFont.mono(9))
                        .foregroundStyle(Self.color(for: t.status))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                }
            }
            if todos.count > 5 {
                Text("+ \(todos.count - 5) more")
                    .font(WFFont.mono(8))
                    .foregroundStyle(WF.ink3)
            }
        }
    }

    private static func mark(for status: String) -> String {
        switch status {
        case "completed":   return "◼"
        case "in_progress": return "▸"
        default:            return "◻"
        }
    }

    private static func color(for status: String) -> Color {
        switch status {
        case "completed":   return WF.done
        case "in_progress": return WF.accent
        default:            return WF.ink3
        }
    }
}

// MARK: - ElapsedTimer

/// 経過時間を 1 秒間隔で更新する極小ビュー。"(1m 26s)" / "(23s)" 形式。
/// Timer.publish は Card が画面外でも動き続けるため、大量の tasks がある
/// 場合は負荷になる可能性あり。MVP では許容 (同時実行 task は数個想定)。
struct ElapsedTimer: View {
    let startedAt: Date
    @State private var now = Date()

    var body: some View {
        Text(formatted)
            .font(WFFont.mono(9))
            .foregroundStyle(WF.ink3)
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { t in
                now = t
            }
    }

    private var formatted: String {
        let delta = max(0, Int(now.timeIntervalSince(startedAt)))
        let m = delta / 60
        let s = delta % 60
        return m > 0 ? "(\(m)m \(s)s)" : "(\(s)s)"
    }
}

// MARK: - LiveLogView

/// TranscriptTailer が AppState.activityLog に積んだ最新エントリを mono font で
/// 流すカード内 mini-console。inProgress / review のカード末尾に配置し、
/// Claude が今「何をしているか」をボード上から一目で追えるようにする。
///
/// **表示ルール (永続 vs 瞬間):**
/// - 永続表示 = user の入力 / assistant の応答テキストのみ。会話の流れを
///   カード上で追うために直近 N 件を残し続ける。
/// - 瞬間表示 = tool 実行ログは永続表示から除外。同じ tool 情報は
///   `ActivityPanel.runningToolRow` が spinner 付きで「今まさに動いている」
///   という形で描画するため、LiveLog に流すと二重表示になる上、過去の
///   tool 実行まで表示されて会話が埋もれる。
///
/// 表示件数は 4 件固定。動的に増減するので、末尾 (最新) のエントリが append
/// されるたび自動的に古いエントリがはみ出してフェードアウトする
/// (`.transition(.opacity)` + SwiftUI の implicit animation に任せる)。
struct LiveLogView: View {
    @Environment(AppState.self) private var appState
    let taskID: UUID

    /// 表示する最大件数。カードの他情報 (tag / title / meta) を圧迫しない
    /// 範囲で 4 件に調整。将来 hover で全件展開する UI を足すなら増やす余地あり。
    private let maxLines = 4

    var body: some View {
        // 永続表示対象は user / assistant のみ。tool / system はスキップ
        // (tool は ActivityPanel が瞬間表示で担当、system はそもそも現状
        // buildEntry で出力しないので実質的には user/assistant フィルタのみ
        // 効く)。
        let all = appState.activityLog[taskID] ?? []
        let persistent = all.filter { $0.kind == .user || $0.kind == .assistant }
        let entries = Array(persistent.suffix(maxLines))
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries, id: \.self) { entry in
                    Text("\(Self.prefix(for: entry.kind)) \(entry.text)")
                        .font(WFFont.mono(9))
                        .foregroundStyle(Self.color(for: entry.kind))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(WF.paperAlt, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(WF.ink3.opacity(0.3), lineWidth: 0.8)
            )
            .animation(.smooth(duration: 0.2), value: appState.activityLog[taskID]?.count)
        }
    }

    private static func prefix(for kind: TranscriptTailer.LogEntry.Kind) -> String {
        switch kind {
        case .user:      return "›"
        case .assistant: return "✦"
        case .tool:      return "→"
        case .system:    return "·"
        }
    }

    private static func color(for kind: TranscriptTailer.LogEntry.Kind) -> Color {
        switch kind {
        case .user:      return WF.ink
        case .assistant: return WF.accent
        case .tool:      return WF.warn
        case .system:    return WF.ink3
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
