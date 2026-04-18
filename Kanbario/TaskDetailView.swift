import SwiftUI

/// 選択中のタスクの詳細を表示する右ペイン。
/// Milestone C で terminal ペインを下半分に差し込む予定。
struct TaskDetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let task = appState.selectedTask {
            detail(for: task)
        } else {
            placeholder
        }
    }

    private func detail(for task: TaskCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // ヘッダ
            HStack {
                statusBadge(task.status)
                Spacer()
                Button(role: .destructive) {
                    appState.deleteTask(id: task.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Delete task")
            }

            Text(task.title)
                .font(.title2).bold()

            // メタデータ
            VStack(alignment: .leading, spacing: 4) {
                LabeledRow(label: "Branch", value: task.branch)
                LabeledRow(label: "Created", value: task.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledRow(label: "Updated", value: task.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }

            Divider()

            // Body (task 内容 = Claude への初回プロンプト)
            Text("Body (Claude prompt)")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(task.body)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color(.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Spacer()

            // Milestone C 予定のアクション枠 (現状は placeholder)
            HStack {
                Button("Start (Milestone C)") { /* TODO: Phase C */ }
                    .disabled(true)
                Spacer()
            }
            .padding(.top, 8)
        }
        .padding(16)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Select a task to see details")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusBadge(_ status: TaskStatus) -> some View {
        Text(status.displayName)
            .font(.caption).bold()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor(status).opacity(0.2))
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
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
