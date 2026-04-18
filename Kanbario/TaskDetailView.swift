import SwiftUI

/// 選択中のタスクの詳細を表示する右ペイン。
/// Milestone C で terminal ペインを下半分に差し込む予定。
struct TaskDetailView: View {
    @Environment(AppState.self) private var appState

    /// Start ボタン連打防止。startTask が await している間 true。
    @State private var isStarting = false

    /// Claude に送る入力欄。TextField バインド用。
    @State private var inputText: String = ""

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

                // セッションログ (claude 稼働中 or 終了後にログがあれば表示)
                if shouldShowSession(task) {
                    sessionPane(for: task)
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

    /// セッションログを表示する条件: claude が動いている、または過去に動いて
    /// ログが残っている場合のみ出す。planning (未起動) では出さない。
    private func shouldShowSession(_ task: TaskCard) -> Bool {
        if appState.activeSessions[task.id] != nil { return true }
        if let log = appState.sessionLogs[task.id], !log.isEmpty { return true }
        return false
    }

    /// ターミナル風のログ + 入力欄 + Stop ボタンをまとめたペイン。
    /// libghostty 導入前の暫定 UI。ANSI は AppState.stripANSI で剥がされた
    /// プレーンテキストが来る前提。
    @ViewBuilder
    private func sessionPane(for task: TaskCard) -> some View {
        let isRunning = appState.activeSessions[task.id] != nil
        let log = appState.sessionLogs[task.id] ?? ""
        let exitCode = appState.sessionExitCodes[task.id]

        VStack(alignment: .leading, spacing: 6) {
            // ヘッダ: 状態 + Stop ボタン
            HStack(spacing: 6) {
                Image(systemName: isRunning ? "terminal.fill" : "terminal")
                    .font(.caption)
                    .foregroundStyle(isRunning ? .green : .secondary)
                Text("Session")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if isRunning {
                    Text("running")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if let code = exitCode {
                    Text("exited (\(code))")
                        .font(.caption2)
                        .foregroundStyle(code == 0 ? Color.secondary : Color.orange)
                }
                Spacer()
                if isRunning {
                    Button(role: .destructive) {
                        Task { await appState.stopTask(id: task.id) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                            Text("Stop")
                        }
                    }
                    .controlSize(.small)
                    .help("SIGTERM を送って claude を止める")
                }
            }

            // ログ本体。bottom marker を使って新しい行が来たら下端に追従する。
            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.isEmpty ? "(no output yet)" : log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                        .id("log-content")
                    Color.clear
                        .frame(height: 1)
                        .id("log-bottom")
                }
                .frame(minHeight: 160, maxHeight: 280)
                .background(Color.black.opacity(0.78))
                .foregroundStyle(.green.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: log) { _, _ in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo("log-bottom", anchor: .bottom)
                    }
                }
            }

            // 入力欄 (running 時のみ)。Enter で送信、Send ボタンでも送信。
            if isRunning {
                HStack(spacing: 6) {
                    TextField("Send to Claude (Enter to submit)", text: $inputText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { submitInput(taskID: task.id) }
                    Button("Send") { submitInput(taskID: task.id) }
                        .buttonStyle(.bordered)
                        .disabled(inputText.isEmpty)
                }
            }
        }
    }

    private func submitInput(taskID: UUID) {
        let text = inputText
        inputText = ""
        Task { await appState.sendInput(taskID: taskID, text: text) }
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
