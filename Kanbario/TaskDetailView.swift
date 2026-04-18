import SwiftUI

/// 選択中のタスクの詳細を表示する右ペイン。
/// Milestone C で terminal ペインを下半分に差し込む予定。
struct TaskDetailView: View {
    @Environment(AppState.self) private var appState

    /// Start ボタン連打防止。startTask が await している間 true。
    @State private var isStarting = false

    var body: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .animation(.smooth(duration: 0.25), value: appState.selectedTaskID)
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
