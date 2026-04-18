import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var isShowingNewTask = false

    var body: some View {
        HSplitView {
            KanbanBoardView()
                .frame(minWidth: 760, idealWidth: 960)
            TaskDetailView()
                .frame(minWidth: 300, idealWidth: 360)
                .frame(maxWidth: 520)
        }
        .frame(minWidth: 1060, minHeight: 580)
        .toolbar {
            ToolbarItem(placement: .principal) {
                repoChip
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingNewTask = true
                } label: {
                    Label("New Task", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New Task (⌘N)")
            }
        }
        .sheet(isPresented: $isShowingNewTask) {
            NewTaskSheet()
        }
        // lastError を alert で表示し、dismiss で state を nil に戻す。
        // .alert(item:) ではなく Bool + message で、String そのものをバインドにはしない
        // (String の identity が一意でないため二重発火する可能性がある)。
        .alert(
            "Kanbario",
            isPresented: Binding(
                get: { appState.lastError != nil },
                set: { if !$0 { appState.lastError = nil } }
            ),
            presenting: appState.lastError
        ) { _ in
            Button("OK", role: .cancel) { appState.lastError = nil }
        } message: { error in
            Text(error)
        }
    }

    /// Toolbar 中央に置くリポジトリ選択 chip。
    /// 未設定: 赤いドット + "Choose Repo…"、設定済み: 緑ドット + ディレクトリ名。
    /// クリックで NSOpenPanel。
    private var repoChip: some View {
        Button {
            chooseRepo()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(appState.repoPath.isEmpty ? Color.red : Color.green)
                    .frame(width: 7, height: 7)
                Image(systemName: "folder")
                    .font(.caption)
                Text(repoLabel)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(appState.repoPath.isEmpty
              ? "Click to choose a git repository"
              : "Repo: \(appState.repoPath) — click to change")
    }

    private var repoLabel: String {
        if appState.repoPath.isEmpty { return "Choose Repo…" }
        return (appState.repoPath as NSString).lastPathComponent
    }

    /// NSOpenPanel でディレクトリを選ばせ、AppState.setRepoPath に流す。
    /// panel.runModal() は MainActor で blocking だが、SwiftUI toolbar の
    /// button action は MainActor 上で走っているので問題ない。
    private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose a git repository"
        panel.prompt = "Select"
        if !appState.repoPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: appState.repoPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            appState.setRepoPath(url.path)
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
