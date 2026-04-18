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
        .padding()
    }
}

/// 1 列分の View。列ヘッダ + タスクカードの縦積み + drop target。
struct KanbanColumn: View {
    @Environment(AppState.self) private var appState
    let status: TaskStatus
    let tasks: [TaskCard]

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(status.displayName)
                    .font(.headline)
                Spacer()
                Text("\(tasks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(tasks) { task in
                        TaskCardView(task: task)
                            .draggable(TaskDrag(id: task.id))
                            .onTapGesture {
                                appState.selectedTaskID = task.id
                            }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            isTargeted
                ? Color.accentColor.opacity(0.15)
                : Color(.controlBackgroundColor)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // カラム全体を drop 受け側にする。TaskDrag を受けて AppState に遷移依頼。
        .dropDestination(for: TaskDrag.self) { drags, _ in
            for drag in drags {
                appState.moveTask(id: drag.id, to: status)
            }
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

/// カード 1 枚分の View。
struct TaskCardView: View {
    @Environment(AppState.self) private var appState
    let task: TaskCard

    var isSelected: Bool { appState.selectedTaskID == task.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title)
                .font(.body)
                .lineLimit(1)
            if !task.body.isEmpty {
                Text(task.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(task.branch)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }
}
