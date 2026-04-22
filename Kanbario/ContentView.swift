import SwiftUI
import AppKit

/// wireframe (Kanban Wireframes.html) の構造に合わせて:
///   - 下層: KanbanBoardView を全幅で表示
///   - 上層: カードクリックで floating モーダルとして TaskDetailView を被せる
/// というオーバーレイ構成に切り替えた。
///
/// **重要:** TaskDetailView は常時マウントする (visibility は opacity +
/// allowsHitTesting のみで切り替える)。`if selectedTaskID != nil { ... }` で
/// conditional mount すると libghostty の NSView identity が解放され、claude が
/// SIGHUP で殺される (PR #4 の根本原因と同じ罠)。
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // NewTaskSheet 表示 state を AppState 側で管理 (App 全体の Commands
        // menu ⌘N からも切り替えられるようにするため)。@Bindable で
        // `$appState.showingNewTaskSheet` として .sheet に渡す。
        @Bindable var state = appState

        ZStack {
            // ── 下層: ボード
            KanbanBoardView(onNewTask: { appState.showingNewTaskSheet = true })
                .opacity(isModalOpen ? 0.45 : 1)
                .allowsHitTesting(!isModalOpen)
                .animation(.smooth(duration: 0.22), value: isModalOpen)

            // ── 上層: モーダル (常時マウント + 可視化のみ切替)
            modalLayer
                .opacity(isModalOpen ? 1 : 0)
                .allowsHitTesting(isModalOpen)
                .animation(.smooth(duration: 0.22), value: isModalOpen)
        }
        .frame(minWidth: 1180, minHeight: 720)
        .background(WF.canvas)
        .foregroundStyle(WF.ink)   // native controls (Toolbar Text 等) が dark mode で白化するのを防ぐ
        .tint(WF.ink)
        .preferredColorScheme(.light)
        .toolbar {
            ToolbarItem(placement: .principal) {
                repoChip
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    openWindow(id: "project-shell")
                } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .help("Open Project Shell (⌘⇧T) — task と無関係な、プロジェクト大元の shell")
            }
        }
        .sheet(isPresented: $state.showingNewTaskSheet) {
            NewTaskSheet()
        }
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
        // カード context menu / モーダルの Delete ボタン、どちらから
        // 呼ばれても dirty 判定で pending を立てるのは AppState.requestDelete。
        // 実際の確認 alert は一箇所にまとめて ContentView で出す (複数箇所に
        // 散らすと、モーダルが閉じた瞬間に alert も消えるなど UX が壊れる)。
        .alert(
            "未コミットの変更があります",
            isPresented: Binding(
                get: { appState.pendingDeleteConfirmation != nil },
                set: { if !$0 { appState.cancelPendingDelete() } }
            ),
            presenting: appState.pendingDeleteConfirmation
        ) { pending in
            Button("削除する", role: .destructive) {
                appState.selectedTaskID = nil
                appState.isTerminalExpanded = false
                Task { await appState.confirmPendingDelete() }
            }
            Button("キャンセル", role: .cancel) {
                appState.cancelPendingDelete()
            }
        } message: { pending in
            Text("\(pending.worktreeDirName) に未コミットの変更があります。削除するとこの変更は失われます。")
        }
        // ESC = modal close は意図的に未実装。ESC は terminal に素通しして
        // claude / vim / less の interrupt キーとして機能させる。ESC による
        // macOS フルスクリーン解除は `GhosttyNSView.keyDown` 側で ESC を
        // consume することで封じている (interpretKeyEvents → cancelOperation
        // 経由の responder chain 伝播を避ける)。代替 close 経路: タイトルバー
        // ×、赤信号ボタン、backdrop クリックの 3 通り。
    }

    // MARK: - Modal

    private var isModalOpen: Bool {
        appState.selectedTaskID != nil
    }

    /// wireframe の半透明 backdrop + ぼかし + 中央モーダルを再現。
    /// backdropFilter: blur(8px) は `.background(.ultraThinMaterial)` で近似。
    ///
    /// **サイズ:** ほぼフル画面 (margin のみ残す)。旧版は maxWidth 1240 /
    /// maxHeight 820 で固定サイズ中央置きだったが、terminal を表示する用途
    /// (inProgress / review) ではできるだけ広い方が読みやすい。planning /
    /// done ではこの広さでも placeholder が中央上寄せで自然に見える。
    private var modalLayer: some View {
        ZStack {
            // backdrop (タップで閉じる)
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { closeModal() }

            TaskDetailView(onClose: closeModal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
        }
    }

    private func closeModal() {
        appState.selectedTaskID = nil
        appState.isTerminalExpanded = false
    }

    // MARK: - Toolbar repo chip (wireframe 手書きスタイル)

    /// Toolbar 中央のリポジトリ選択ピル。NSWindow のタイトルバーに載るので、
    /// 手書きフォントは使わず system UI に合わせた押しやすい見た目を維持。
    private var repoChip: some View {
        Button(action: chooseRepo) {
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
