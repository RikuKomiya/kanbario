import SwiftUI
import CoreGraphics
import UniformTypeIdentifiers

/// Kanban ボード本体。4 列を横並びで表示する。
struct KanbanBoardView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                KanbanColumn(
                    status: status,
                    tasks: appState.tasks(in: status)
                )
            }
        }
        .padding(14)
        .background(Color(.windowBackgroundColor))
    }
}

/// 1 列分の View。列ヘッダ + タスクカードの縦積み + drop target。
struct KanbanColumn: View {
    @Environment(AppState.self) private var appState
    let status: TaskStatus
    let tasks: [TaskCard]

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider().opacity(0.4)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    if tasks.isEmpty {
                        emptyState
                            .padding(.top, 40)
                    } else {
                        ForEach(tasks) { task in
                            taskRow(task)
                        }
                    }
                    // Ghost placeholder: drag 中、cursor がこの列に入っていて
                    // かつ source が別列の時だけ、末尾に「ここに落ちる」プレビューを出す。
                    // OS の drag preview は AppKit 管理で再描画が効かないので、
                    // SwiftUI view tree 内のこのゴーストが drop-location の主要な視覚シグナル。
                    if let dragging = appState.draggingTask,
                       dragging.status != status,
                       isTargeted {
                        DropPlaceholderCard(task: dragging, accent: statusTint)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(columnBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isTargeted ? statusTint.opacity(0.6) : Color.clear, lineWidth: 2)
        )
        .onDrop(of: [.utf8PlainText], delegate: KanbanColumnDropDelegate(
            status: status,
            appState: appState,
            isTargeted: $isTargeted
        ))
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        .animation(.easeInOut(duration: 0.15), value: appState.draggingTaskID)
    }

    // MARK: - Row

    @ViewBuilder
    private func taskRow(_ task: TaskCard) -> some View {
        Button {
            appState.selectedTaskID = task.id
        } label: {
            TaskCardView(
                task: task,
                accent: statusTint,
                isSelected: appState.selectedTaskID == task.id,
                activity: appState.activitiesByTaskID[task.id]
            )
        }
        .buttonStyle(.plain)
        // drag 中は source card を opacity 0 で隠す。
        .opacity(appState.draggingTaskID == task.id ? 0 : 1)
        // preview closure を渡さず、OS default の view snapshot に任せる (langwatch/kanban-code 方式)。
        // 理由:
        // - EmptyView / 1x1 Color.clear preview では drag 中の視認性が失われる / crash
        // - 自前 preview (opacity binding) は AppKit NSImage に焼き付いてしまい再描画されない
        // - SwiftUI の範囲で drop 残像を消す API は存在しない (NSDraggingSession.animatesToDestination
        //   は NSViewRepresentable まで降りないと触れない)
        // → drop 時の AppKit 標準 fade アニメは macOS 流儀として受け入れ、ユーザの視線は
        //   DropPlaceholderCard のゴースト消滅 + 新列への instant 出現に誘導する。
        //
        // drag 終了検知: CGEventSource で mouse button を 30ms polling。DropDelegate の
        // dropExited は列外ヒットでしか発火しないため、ウィンドウ外で release された時の
        // state cleanup に必要。
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

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusTint)
                .frame(width: 8, height: 8)
            Text(status.displayName)
                .font(.system(.subheadline, design: .default, weight: .semibold))
            Spacer()
            Text("\(tasks.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: isTargeted ? "arrow.down.circle.fill" : "tray")
                .font(.system(size: 24))
                .foregroundStyle(isTargeted ? statusTint : Color.secondary.opacity(0.4))
            Text(isTargeted ? "Drop here" : "No tasks")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var columnBackground: some View {
        ZStack {
            Color(.controlBackgroundColor)
            if isTargeted {
                statusTint.opacity(0.08)
            }
        }
    }

    private var statusTint: Color {
        switch status {
        case .planning:   return Color.gray
        case .inProgress: return Color.blue
        case .review:     return Color.orange
        case .done:       return Color.green
        }
    }
}

// MARK: - Drop handling

/// 列ごとの drop handler。
/// - `dropUpdated` で `DropProposal(operation: .move / .forbidden)` を返すと
///   cursor に `+` / `⊘` マークが出て drop 可否がユーザーに伝わる。
/// - `performDrop` はペイロード (UUID 文字列) を pasteboard 経由で読まず、
///   `appState.draggingTaskID` を直接参照する (state がすでに在ることを利用して async な
///   `loadObject` を避け、drop 応答を同期にする)。
struct KanbanColumnDropDelegate: DropDelegate {
    let status: TaskStatus
    let appState: AppState
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let id = appState.draggingTaskID,
              let current = appState.tasks.first(where: { $0.id == id })?.status
        else {
            return DropProposal(operation: .forbidden)
        }
        // 同じ列への drop は「何もしない」だが、forbidden 扱いにすると
        // source 列 hover 中に赤マークが出て違和感があるので許可扱い。
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

// MARK: - Cards

/// カード 1 枚分の表示 View。@Environment を読まない純粋な presentation。
struct TaskCardView: View {
    let task: TaskCard
    var accent: Color = .gray
    var isSelected: Bool = false
    /// hook event で更新される即時状態。nil なら何も描画しない
    /// (= planning / done、もしくは session-end 後)。
    var activity: ClaudeActivity? = nil

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Rectangle()
                    .fill(accent)
                    .frame(width: 3)
                    .clipShape(Capsule())
                Text(task.title)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let activity {
                    Spacer(minLength: 4)
                    ActivityBadge(activity: activity)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if !task.body.isEmpty {
                Text(task.body)
                    .font(.system(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(task.branch.replacingOccurrences(of: "kanbario/", with: ""))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? accent : Color.black.opacity(0.08),
                        lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: .black.opacity(isHovering ? 0.12 : 0.05),
                radius: isHovering ? 6 : 2,
                y: isHovering ? 3 : 1)
        .scaleEffect(isHovering ? 1.012 : 1.0)
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.15), value: isHovering)
    }
}

/// Drop 先 column に挿入される半透明プレースホルダ。
/// OS の drag preview と違い SwiftUI view tree の一員なので、`isTargeted` の
/// 変化に対して `.transition` が効く。drop 確定と同時に自然に fade out する。
struct DropPlaceholderCard: View {
    let task: TaskCard
    let accent: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Rectangle()
                .fill(accent)
                .frame(width: 3)
                .clipShape(Capsule())
            Text(task.title)
                .font(.system(.body, weight: .medium))
                .lineLimit(2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(accent.opacity(0.55),
                              style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        )
        .opacity(0.8)
    }
}

// MARK: - Activity badge

/// カード右上に出す「claude が何をしているか」の小バッジ。
/// カラムの意味論 (inProgress / review) はボード全体で伝わるので、
/// ここでは 1 カード単位の finer-grained な信号を 1 行で見せる。
struct ActivityBadge: View {
    let activity: ClaudeActivity

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
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
