import SwiftUI

/// 選択中のタスクの詳細を表示する右ペイン。
/// Milestone C で terminal ペインを下半分に差し込む予定。
struct TaskDetailView: View {
    @Environment(AppState.self) private var appState

    /// Start ボタン連打防止。startTask が await している間 true。
    @State private var isStarting = false

    var body: some View {
        VStack(spacing: 0) {
            // expanded 時は detail (title / metadata / body / Start ボタン) を
            // 高さ 0 に潰して隠すだけ。`if !expanded` で conditional mount
            // すると VStack の子配列の要素数が変わり、terminalArea の identity
            // (そこに居る libghostty NSView) が SwiftUI に「別物」と判断されて
            // dismantle されるリスクがある。detail 側には NSView はないので
            // 安全に消せる ― でも兄弟の terminalArea を守るため残す。
            Group {
                if let task = appState.selectedTask {
                    detail(for: task)
                        .transition(.asymmetric(
                            insertion: .opacity,
                            removal: .opacity
                        ))
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: appState.isTerminalExpanded ? 0 : .infinity)
            .opacity(appState.isTerminalExpanded ? 0 : 1)
            .allowsHitTesting(!appState.isTerminalExpanded)
            .clipped()

            terminalArea
        }
        .background(Color(.windowBackgroundColor))
        .animation(.smooth(duration: 0.25), value: appState.selectedTaskID)
        // ESC / Collapse ボタンと同じく、expanded モード中は Cmd+. でも戻せる。
        .background(
            Button("") {
                if appState.isTerminalExpanded {
                    appState.isTerminalExpanded = false
                }
            }
            .keyboardShortcut(.cancelAction)
            .hidden()
        )
    }

    /// 全 active surface を常時マウントする terminal area。
    ///
    /// libghostty の surface は NSView と寿命を共有する設計 (surface 内で nsview
    /// ポインタを直接保持) なので、SwiftUI に view identity を切り替えさせると
    /// `dismantleNSView` → `ghostty_surface_free` → 子プロセス (claude) に SIGHUP
    /// で claude が殺される。さらに activeSurfaces 側はゾンビ TerminalSurface が
    /// 残るので、再表示で `viewDidMoveToWindow` → `attachToView` → surface == nil →
    /// `createSurface` で **新しい claude が fork** されてしまう (ユーザー報告
    /// バグ #1 / #2 の根本原因)。
    ///
    /// 対策: ZStack で全 surface を重ね、選択中以外は `.opacity(0)` +
    /// `.allowsHitTesting(false)`。view identity が安定するので NSView は
    /// 「surface が本当に消える時」(Stop / hook close / done drag) だけ
    /// dismantle される正しい semantics になる。
    /// 現在 terminalArea で表に見せる surface の ID。
    /// - shell タブが選ばれていればその ID
    /// - そうでなければ現在選択中タスクの ID (claude surface)
    private var activeTerminalID: UUID? {
        if let shell = appState.selectedTerminalID,
           appState.shellSurfaces[shell] != nil {
            return shell
        }
        return appState.selectedTaskID
    }

    @ViewBuilder
    private var terminalArea: some View {
        // `activeSurfaces.keys` は Swift Dictionary なので**順序非決定**。
        // ForEach(id: \.self) に流し込むと、レンダリングのたびに順序がブレて
        // SwiftUI の identity 追跡が破綻し、GhosttyNSView を dismantle してしまう
        // (= claude 殺害)。tasks 配列の順序でフィルタして決定的に取り出す。
        let taskIDs = appState.tasks.compactMap { task in
            appState.activeSurfaces[task.id] != nil ? task.id : nil
        }
        let shellIDs = appState.shellTabOrder
        if !taskIDs.isEmpty || !shellIDs.isEmpty {
            VStack(spacing: 0) {
                if appState.isTerminalExpanded {
                    // expanded 中のみタブバーを出す。通常モードは従来どおり
                    // タスクに紐付いた 1 surface を見せるだけなのでタブ不要。
                    tabBar(taskIDs: taskIDs, shellIDs: shellIDs)
                }

                ZStack {
                    // タスク surface (claude)
                    ForEach(taskIDs, id: \.self) { taskID in
                        if let surface = appState.activeSurfaces[taskID],
                           let task = appState.tasks.first(where: { $0.id == taskID }) {
                            terminalPane(task: task, surface: surface)
                                .opacity(taskID == activeTerminalID ? 1 : 0)
                                .allowsHitTesting(taskID == activeTerminalID)
                        }
                    }
                    // shell タブ surface
                    ForEach(shellIDs, id: \.self) { shellID in
                        if let surface = appState.shellSurfaces[shellID] {
                            shellTabPane(id: shellID, surface: surface)
                                .opacity(shellID == activeTerminalID ? 1 : 0)
                                .allowsHitTesting(shellID == activeTerminalID)
                        }
                    }
                }
            }
            .frame(
                minHeight: 280,
                maxHeight: appState.isTerminalExpanded ? .infinity : 520
            )
            .padding(
                [.horizontal, .bottom],
                appState.isTerminalExpanded ? 0 : 18
            )
        }
    }

    /// expanded 中のみ表示されるタブバー。claude タスク (1 本) + shell タブ (0..n)
    /// + 「+」(新規 shell タブ) が並ぶ。`⌘T` は新規タブボタンに keyboardShortcut
    /// を仕込むことで expanded 中だけ active になる (disabled で通常モード時は
    /// OS の default ⌘T に流す)。
    @ViewBuilder
    private func tabBar(taskIDs: [UUID], shellIDs: [UUID]) -> some View {
        HStack(spacing: 4) {
            // 選択中タスクの claude タブ (タスクが active の時だけ表示)
            if let taskID = appState.selectedTaskID,
               appState.activeSurfaces[taskID] != nil,
               let task = appState.tasks.first(where: { $0.id == taskID }) {
                tabButton(
                    title: task.title,
                    icon: "sparkles",
                    isSelected: activeTerminalID == taskID,
                    onSelect: { appState.selectedTerminalID = nil },
                    onClose: nil
                )
            }

            ForEach(Array(shellIDs.enumerated()), id: \.element) { index, shellID in
                tabButton(
                    title: "Shell \(index + 1)",
                    icon: "terminal",
                    isSelected: activeTerminalID == shellID,
                    onSelect: { appState.selectedTerminalID = shellID },
                    onClose: { appState.requestCloseShellTab(id: shellID) }
                )
            }

            Button {
                appState.openShellTab()
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .keyboardShortcut("t", modifiers: .command)
            .help("New shell tab (⌘T)")

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
    }

    private func tabButton(
        title: String,
        icon: String,
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        onClose: (() -> Void)?
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160, alignment: .leading)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    /// shell タブ用の pane。claude と違ってヘッダに activity ラベルや Stop は要らない。
    @ViewBuilder
    private func shellTabPane(id: UUID, surface: TerminalSurface) -> some View {
        GhosttyTerminalView(
            terminalSurface: surface,
            isSelected: id == activeTerminalID,
            onCloseRequested: { _ in
                appState.handleShellTabClosed(id: id)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func detail(for task: TaskCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // ヘッダ
                HStack {
                    statusBadge(task.status)
                    Spacer()
                    Button(role: .destructive) {
                        withAnimation(.smooth(duration: 0.25)) {
                            appState.deleteTask(id: task.id)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help("Delete task")
                }

                Text(task.title)
                    .font(.system(.title2, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                // メタデータ
                VStack(alignment: .leading, spacing: 6) {
                    LabeledRow(
                        icon: "arrow.triangle.branch",
                        label: "Branch",
                        value: task.branch,
                        monospaced: true
                    )
                    LabeledRow(
                        icon: "calendar",
                        label: "Created",
                        value: task.createdAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    LabeledRow(
                        icon: "clock",
                        label: "Updated",
                        value: task.updatedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                .padding(10)
                .background(Color(.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Body
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "text.alignleft")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Claude prompt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(task.body)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(Color(.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.black.opacity(0.08))
                        )
                }

                // libghostty ターミナルペインは ScrollView 外の `terminalArea`
                // に移動 (全 active surface を常時マウントして claude 殺害を回避、
                // 詳細は terminalArea のコメント参照)。

                // Milestone C: Start ボタン
                HStack {
                    Button {
                        isStarting = true
                        Task {
                            await appState.startTask(task)
                            isStarting = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isStarting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text(isStarting ? "Starting…" : "Start")
                        }
                        .frame(minWidth: 90)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canStart(task))
                    .help(startHelpText(task))

                    Spacer()
                }
                .padding(.top, 4)
            }
            .padding(18)
        }
    }

    /// Start ボタンが押せるかの判定。planning 状態かつリポジトリ設定済み、
    /// かつ起動中でない時のみ true。
    private func canStart(_ task: TaskCard) -> Bool {
        task.status == .planning && appState.canStartTasks && !isStarting
    }

    /// ヘッダ + GhosttyTerminalView + Stop ボタン。入力は GhosttyNSView が
    /// 直接 libghostty の surface に渡すので、別の input field は持たない。
    @ViewBuilder
    private func terminalPane(task: TaskCard, surface: TerminalSurface) -> some View {
        let activity = appState.activitiesByTaskID[task.id]
        VStack(alignment: .leading, spacing: 6) {
            // ヘッダ: activity ラベル + Stop ボタン
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.caption)
                    .foregroundStyle(sessionTint(activity))
                Text("Session")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(sessionLabel(activity))
                    .font(.caption2)
                    .foregroundStyle(sessionTint(activity))
                if let activity {
                    ActivityBadge(activity: activity)
                }
                Spacer()

                // Expand / Collapse は同じスロット。expanded の時のみ選択中の
                // タスクでアクティブにしたいので、hit test は selectedTask ==
                // task.id を前提に effectively 1 つだけ働く (terminalArea の
                // .allowsHitTesting と同じ理屈)。
                Button {
                    appState.isTerminalExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: appState.isTerminalExpanded
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                        Text(appState.isTerminalExpanded ? "Collapse" : "Expand")
                    }
                }
                .controlSize(.small)
                .help(appState.isTerminalExpanded
                      ? "ターミナルを通常サイズに戻す (ESC / ⌘.)"
                      : "ターミナルを全画面で表示")

                Button(role: .destructive) {
                    appState.stopTask(id: task.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                        Text("Stop")
                    }
                }
                .controlSize(.small)
                .help("SIGHUP を送って claude を止める")
            }

            let taskID = task.id
            GhosttyTerminalView(
                terminalSurface: surface,
                isSelected: taskID == activeTerminalID,
                onCloseRequested: { _ in
                    appState.handleSurfaceClosed(taskID: taskID)
                }
            )
            .frame(minHeight: 280, maxHeight: 520)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Session ヘッダの左側テキスト。activity 不明 (= session-end 後など) は
    /// ニュートラルな "idle" にフォールバックする。
    private func sessionLabel(_ activity: ClaudeActivity?) -> String {
        switch activity {
        case .running:    return "working"
        case .needsInput: return "awaiting input"
        case nil:         return "idle"
        }
    }

    private func sessionTint(_ activity: ClaudeActivity?) -> Color {
        switch activity {
        case .running:    return .green
        case .needsInput: return .orange
        case nil:         return Color(nsColor: .secondaryLabelColor)
        }
    }

    /// 押せない理由を tooltip で開示する。
    private func startHelpText(_ task: TaskCard) -> String {
        if task.status != .planning { return "Only planning tasks can be started" }
        if !appState.canStartTasks { return "Choose a repository first (toolbar)" }
        if isStarting { return "Starting…" }
        return "Start Claude (wt switch + claude spawn)"
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Select a task to see details")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusBadge(_ status: TaskStatus) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(badgeColor(status))
                .frame(width: 7, height: 7)
            Text(status.displayName)
                .font(.system(.caption, weight: .semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(badgeColor(status).opacity(0.15))
        .foregroundStyle(badgeColor(status))
        .clipShape(Capsule())
    }

    private func badgeColor(_ status: TaskStatus) -> Color {
        switch status {
        case .planning:   return .gray
        case .inProgress: return .blue
        case .review:     return .orange
        case .done:       return .green
        }
    }
}

private struct LabeledRow: View {
    let icon: String
    let label: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
