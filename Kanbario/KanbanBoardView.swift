import SwiftUI

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
                // 小さなカード数なら LazyVStack は不要 (lazy が drag 中に flicker の原因)
                VStack(spacing: 8) {
                    if tasks.isEmpty {
                        emptyState
                            .padding(.top, 40)
                    } else {
                        ForEach(tasks) { task in
                            taskRow(task)
                        }
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
        .dropDestination(for: TaskDrag.self) { drags, _ in
            withAnimation(.smooth(duration: 0.28)) {
                for drag in drags {
                    appState.moveTask(id: drag.id, to: status)
                }
            }
            return true
        } isTargeted: { isTargeted = $0 }
    }

    // MARK: - Row

    @ViewBuilder
    private func taskRow(_ task: TaskCard) -> some View {
        // Button + .plain で tap を処理 (onTapGesture と違い、draggable との干渉が少ない)
        Button {
            appState.selectedTaskID = task.id
        } label: {
            TaskCardView(
                task: task,
                accent: statusTint,
                isSelected: appState.selectedTaskID == task.id
            )
        }
        .buttonStyle(.plain)
        .draggable(TaskDrag(id: task.id)) {
            // Drag preview: @Environment を使わない独立 View
            TaskCardDragPreview(task: task, accent: statusTint)
                .frame(width: 260)
        }
        .transition(.asymmetric(
            // 旧列から消える時は instant (残像を残さない)、新列に入る時だけ scale-in
            insertion: .opacity.combined(with: .scale(scale: 0.95)),
            removal:   .identity
        ))
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

/// カード 1 枚分の表示 View。@Environment を読まない純粋な presentation。
/// Drag preview でも再利用するため selection state を parameter として受ける。
struct TaskCardView: View {
    let task: TaskCard
    var accent: Color = .gray
    var isSelected: Bool = false

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

/// Drag preview 用。独立した軽量 View で @Environment 非依存。
struct TaskCardDragPreview: View {
    let task: TaskCard
    let accent: Color

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
            }
            if !task.body.isEmpty {
                Text(task.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accent.opacity(0.5), lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .rotationEffect(.degrees(-2))
    }
}
