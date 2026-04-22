import SwiftUI

/// 「Project Shell」ウィンドウ本体。task に紐付かない、プロジェクトの大元
/// (`AppState.repoPath`) で開く汎用シェルをまとめる。Window scene として
/// KanbarioApp に登録されており、singleton で 1 枚だけ存在する。
///
/// **設計方針:**
/// - 複数タブ可 (⌘T で追加、× で閉じる)。タブデータは AppState.projectShell*
///   に保持し、ウィンドウが閉じられても surface は生き続ける (再度 open
///   すれば続きから使える)。
/// - split は MVP では非対応 (TaskDetailView のそれを真似すると複雑なので
///   後回し。必要になったら追加)。
/// - libghostty の NSView identity を壊さないため、全タブを常時 ZStack で
///   mount し、選択タブだけ opacity 1 にする (TaskDetailView.paneStack と
///   同じパターン — cmux の罠回避)。
struct ProjectShellView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .background(Color(white: 0.12))
                .overlay(Divider().background(WF.shellDivider), alignment: .bottom)

            paneStack
                .background(WF.shellBg)
                .frame(minWidth: 720, minHeight: 420)
        }
        .background(WF.shellBg)
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            // Window が見えたタイミングで最低 1 タブは用意する。
            // ウィンドウを一度閉じて再度開いた時に空ウィンドウにならない
            // 安全弁でもある (projectShellTabOrder が空なら再確保)。
            appState.ensureProjectShellReady()
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(appState.projectShellTabOrder.enumerated()), id: \.element) { index, id in
                projectTabChip(index: index, id: id)
            }
            Button {
                appState.openProjectShellTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.75))
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("t", modifiers: .command)
            .help("New shell tab (⌘T)")

            Spacer()

            repoHint
                .padding(.trailing, 12)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    /// cwd のヒントを右上に小さく表示 (「今どこのディレクトリで shell が
    /// 立ち上がっているか」一目で分かるように)。
    @ViewBuilder
    private var repoHint: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.6))
            Text(repoLabel)
                .font(WFFont.mono(10))
                .foregroundStyle(Color(white: 0.75))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var repoLabel: String {
        if appState.repoPath.isEmpty { return "no repo (cwd = $HOME)" }
        return (appState.repoPath as NSString).lastPathComponent
    }

    /// タブ 1 つ。「shell #N」+ × ボタンの最小構成 (TaskDetailView の TabChip
    /// は fileprivate で再利用しにくいので、ここ専用に小さく書く)。
    @ViewBuilder
    private func projectTabChip(index: Int, id: UUID) -> some View {
        let isActive = appState.selectedProjectShellID == id
        HStack(spacing: 6) {
            Button {
                appState.selectedProjectShellID = id
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(isActive ? Color.white : Color(white: 0.6))
                    Text("shell #\(index + 1)")
                        .font(WFFont.mono(11))
                        .foregroundStyle(isActive ? Color.white : Color(white: 0.75))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                appState.requestCloseProjectShellTab(id: id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(white: 0.6))
                    .padding(.horizontal, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color(white: 0.22) : Color.clear)
        )
    }

    // MARK: - Panes

    /// 全タブを ZStack で常時 mount。focused だけ opacity 1 / hit 有効に
    /// する。タブが 0 個なら空状態を表示 (直後に ensureProjectShellReady が
    /// 発火して埋まるので、ほぼ見えない過渡状態)。
    @ViewBuilder
    private var paneStack: some View {
        ZStack {
            ForEach(appState.projectShellTabOrder, id: \.self) { id in
                if let surface = appState.projectShellSurfaces[id] {
                    let show = appState.selectedProjectShellID == id
                    GhosttyTerminalView(
                        terminalSurface: surface,
                        isSelected: show,
                        onCloseRequested: { _ in
                            appState.handleProjectShellClosed(id: id)
                        }
                    )
                    .opacity(show ? 1 : 0)
                    .allowsHitTesting(show)
                }
            }
            if appState.projectShellTabOrder.isEmpty {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Opening shell…")
                        .font(WFFont.mono(11))
                        .foregroundStyle(Color(white: 0.7))
                }
            }
        }
    }
}
