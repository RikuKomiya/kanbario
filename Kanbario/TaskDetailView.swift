import SwiftUI

/// Kanban Wireframes.html の「terminal modal」セクション相当の詳細モーダル。
///
/// レイアウト (wireframe に準拠):
///   [title bar]  traffic lights + tag pill + task title       [split toggle] [×]
///   [meta strip] status · owner · prompt · branch · eval · risk
///   [tab bar]    claude tab + shell tabs + +           ⌘T/⌘D/⌘W hint
///   [panes]      (single or vertical split)
///   [footer]     shell connected · pid · N tabs · split view
///
/// Planning ステージはまだ surface が無いので「body プレビュー + Start ボタン」
/// を pane の代わりに出す。Done は PR 情報を出して terminal は表示しない。
///
/// **重要:** libghostty NSView identity を壊さない。surface は activeSurfaces /
/// shellSurfaces に生きている限り ZStack で常時マウント、見せる surface だけ
/// opacity 1 にする (従来の terminalArea と同じ方針)。ContentView 側でも
/// conditional mount は避けている (PR #4 参照)。
struct TaskDetailView: View {
    @Environment(AppState.self) private var appState
    var onClose: () -> Void = {}

    /// Start ボタン連打防止。
    @State private var isStarting = false
    /// split モーダル内の右ペインに出すタブ ID。左は activeTerminalID。
    @State private var rightTerminalID: UUID? = nil

    /// **重要:** body は task 選択状態に関わらず常に `panesArea` を含む構造を
    /// 返す。`if let task = selectedTask` で subtree を差し替えると ZStack 内の
    /// libghostty NSView が unmount され、claude が SIGHUP で殺される
    /// (モーダルを閉じた瞬間に session が死に、再 open で surface 再生成 = 別
    /// claude が起動するバグの根本原因)。タスク特有の chrome (title bar /
    /// meta strip / tab bar / footer) は内部で空描画に切り替えるが、panesArea
    /// は例外なく同じ位置・同じ identity で render する。
    var body: some View {
        VStack(spacing: 0) {
            titleBarSection
            Divider().overlay(WF.line).opacity(0.6)

            metaSection
            Divider().overlay(WF.line).opacity(0.6)

            // tab bar は常時表示 (中身は surface の有無で変わる)
            tabBar
                .background(WF.paperAlt)
            Divider().overlay(WF.line).opacity(0.6)

            // ★ identity 維持の要: task 未選択でも panesArea は必ずマウントする。
            //   中身が空 (activeSurfaces / shellSurfaces がゼロ) でも ZStack は
            //   render コストほぼゼロ。逆に subtree を消すと PR #4 の罠を再現する。
            ZStack {
                panesArea
                    .opacity(hasAnyTerminal ? 1 : 0)
                    .allowsHitTesting(hasAnyTerminal)

                // terminal が無い時に上に重ねる stage placeholder (Planning / Done)
                if let task = appState.selectedTask, !hasAnyTerminal {
                    stagePlaceholder(for: task)
                        .background(WF.paper)
                }
            }

            Divider().overlay(WF.line).opacity(0.6)
            footerSection
                .background(WF.paperAlt)
        }
        .background(WF.paper)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(WF.line, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: Color.black.opacity(0.3), radius: 30, x: 0, y: 20)
        // review ステージのタスクが選ばれ、まだ surface が無い時は
        // `claude --continue` で自動復帰する。nil → id の遷移で発火。
        .onChange(of: appState.selectedTaskID) { _, newID in
            guard let id = newID,
                  let task = appState.tasks.first(where: { $0.id == id })
            else { return }
            Task { await appState.resumeTask(task) }
        }
    }

    // MARK: - Conditional sections (空描画可)

    /// task 選択時は wireframe title bar、未選択時は空の高さ 44 のバー。
    /// panesArea の identity を保つため subtree 構造は常に同じ高さで返す。
    @ViewBuilder
    private var titleBarSection: some View {
        if let task = appState.selectedTask {
            titleBar(for: task)
        } else {
            HStack { TrafficLights(onClose: onClose); Spacer() }
                .padding(.horizontal, 14)
                .frame(height: 44)
        }
    }

    @ViewBuilder
    private var metaSection: some View {
        if let task = appState.selectedTask {
            metaStrip(for: task)
        } else {
            Color.clear.frame(height: 40)
        }
    }

    @ViewBuilder
    private var footerSection: some View {
        if let task = appState.selectedTask {
            footer(for: task)
        } else {
            Color.clear.frame(height: 34)
        }
    }

    // MARK: - Title bar

    @ViewBuilder
    private func titleBar(for task: TaskCard) -> some View {
        HStack(spacing: 10) {
            TrafficLights(onClose: onClose)
            HStack(spacing: 8) {
                if let tag = task.tag {
                    LLMTagPill(tag: tag, size: 11)
                }
                Hand(task.title, size: 15, weight: .bold)
            }
            .padding(.leading, 10)

            Spacer()

            // Split 切替 (terminal が存在する時だけ意味がある)
            if hasAnyTerminal {
                splitToggle
            }

            Button(action: onClose) { WFIcon.close() }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var splitToggle: some View {
        HStack(spacing: 0) {
            Button {
                appState.isTerminalExpanded = false
                rightTerminalID = nil
            } label: {
                Image(systemName: "rectangle")
                    .font(.system(size: 13))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(!appState.isTerminalExpanded ? WF.ink : Color.clear)
                    .foregroundStyle(!appState.isTerminalExpanded ? WF.paper : WF.ink2)
            }
            .buttonStyle(.plain)

            Divider().frame(width: 1, height: 22).background(WF.line)

            Button {
                appState.isTerminalExpanded = true
                primeRightTabIfNeeded()
            } label: {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 13))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(appState.isTerminalExpanded ? WF.ink : Color.clear)
                    .foregroundStyle(appState.isTerminalExpanded ? WF.paper : WF.ink2)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("d", modifiers: .command)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(WF.line, lineWidth: 1.2))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// split 有効化時に右ペインのデフォルトタブを決める。
    ///
    /// 優先順:
    ///   1. 既存の shell タブのうち、activeLeftID と **異なる** もの
    ///      (同じ surface を左右で mount すると libghostty が attach 競合する)
    ///   2. 見つからなければ新規 shell を作成 — `selectAsLeftPane: false` で
    ///      selectedTerminalID を奪わないようにする
    private func primeRightTabIfNeeded() {
        guard rightTerminalID == nil else { return }
        if let firstDifferent = appState.shellTabOrder.first(where: { $0 != activeLeftID }) {
            rightTerminalID = firstDifferent
        } else {
            rightTerminalID = appState.openShellTab(selectAsLeftPane: false)
        }
    }

    // MARK: - Meta strip

    @ViewBuilder
    private func metaStrip(for task: TaskCard) -> some View {
        HStack(spacing: 20) {
            Metric(label: "status", value: task.status.displayName,
                   color: task.status.dotColor)
            Metric(label: "owner", value: task.owner ?? "—")
            Metric(label: "prompt", value: task.promptV ?? "—")
            Metric(label: "branch",
                   value: task.branch.replacingOccurrences(of: "kanbario/", with: ""),
                   color: WF.accent)
            if let eval = task.evalScore {
                Metric(label: "eval", value: "\(Int((eval*100).rounded()))",
                       color: eval >= 0.85 ? WF.done : WF.warn)
            }
            Spacer()
            if let risk = task.risk { RiskBadge(risk: risk) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Tab bar

    private var hasAnyTerminal: Bool {
        guard let id = appState.selectedTaskID else { return false }
        if appState.activeSurfaces[id] != nil { return true }
        return !appState.shellTabOrder.isEmpty
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            // Claude タブ (アクティブな task surface があれば)
            if let id = appState.selectedTaskID,
               appState.activeSurfaces[id] != nil,
               let task = appState.tasks.first(where: { $0.id == id }) {
                TabChip(
                    title: task.title,
                    icon: "sparkles",
                    isActive: activeLeftID == id,
                    showClose: false,
                    onSelect: { appState.selectedTerminalID = nil },
                    onClose: nil
                )
            }
            ForEach(Array(appState.shellTabOrder.enumerated()), id: \.element) { index, shellID in
                TabChip(
                    title: "zsh #\(index + 1)",
                    icon: "chevron.left.forwardslash.chevron.right",
                    isActive: activeLeftID == shellID,
                    showClose: true,
                    onSelect: { appState.selectedTerminalID = shellID },
                    onClose: { appState.requestCloseShellTab(id: shellID) }
                )
            }
            Button {
                appState.openShellTab()
            } label: {
                WFIcon.plus()
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("t", modifiers: .command)
            .help("New shell tab (⌘T)")

            Spacer()

            Hand("⌘T new · ⌘D split · ⌘W close", size: 11, color: WF.ink3)
                .padding(.trailing, 14)
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
    }

    // MARK: - Panes

    /// 現在左ペインに表示する surface の ID。
    /// shell が選ばれていればそれ、そうでなければ選択中 task の claude surface。
    private var activeLeftID: UUID? {
        if let shell = appState.selectedTerminalID,
           appState.shellSurfaces[shell] != nil {
            return shell
        }
        return appState.selectedTaskID
    }

    /// 左右ペインに mount する surface ID を排他に配分する。
    /// libghostty の `TerminalSurface` は NSView 1 つと寿命を共有するため、
    /// 同一 surface を 2 ペインで mount すると attach が後勝ちになって
    /// 先に attach した側の入力が通らなくなる。split 時は rightTerminalID を
    /// 右ペイン「だけ」に配り、左ペインは残り全て、と明確に分離する。
    private var panesArea: some View {
        let split = appState.isTerminalExpanded
        let rightID = split ? rightTerminalID : nil
        let leftIDs = allSurfaceIDs.filter { $0 != rightID }
        let rightIDs = rightID.map { [$0] } ?? []

        return HStack(spacing: 0) {
            paneStack(mountIDs: leftIDs, focusedID: activeLeftID)

            if split {
                Rectangle()
                    .fill(WF.shellDivider)
                    .frame(width: 1)
                VStack(spacing: 0) {
                    rightPaneTabBar
                    paneStack(mountIDs: rightIDs, focusedID: rightID)
                }
            }
        }
        .background(WF.shellBg)
        .frame(minHeight: 320)
    }

    /// 全 surface (task claude + shell) の ID を並び順を保って返す。
    /// `paneStack` はこのリストから割り当て先を絞り込んで mount する。
    private var allSurfaceIDs: [UUID] {
        var ids: [UUID] = []
        // task 側は tasks 配列の順で (Dictionary は順序非保持なので、常に
        // 決定的な順序に正規化するために明示ループ)
        for task in appState.tasks where appState.activeSurfaces[task.id] != nil {
            ids.append(task.id)
        }
        ids.append(contentsOf: appState.shellTabOrder)
        return ids
    }

    /// 右ペインの inner tab bar。左ペインと同じ shell を右にアサインすると
    /// libghostty が二重 attach で壊れるため、activeLeftID に一致するタブは
    /// リストから除外 (右で使いたければ、まず左で別タブに切り替えてから選ぶ)。
    private var rightPaneTabBar: some View {
        let candidates = appState.shellTabOrder.enumerated().filter { _, id in id != activeLeftID }
        return HStack(spacing: 4) {
            ForEach(Array(candidates), id: \.element) { index, shellID in
                Button {
                    rightTerminalID = shellID
                } label: {
                    Text("zsh #\(index + 1)")
                        .font(WFFont.mono(10))
                        .foregroundStyle(Color(white: 0.82))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(rightTerminalID == shellID
                                    ? Color(white: 0.22)
                                    : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            // 全タブが activeLeftID 1 個しかない場合に「新規右ペインタブ」を
            // すぐ開ける `+` ボタン。
            Button {
                if let id = appState.openShellTab(selectAsLeftPane: false) {
                    rightTerminalID = id
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.75))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(white: 0.17))
        .overlay(Divider().background(WF.shellDivider), alignment: .bottom)
    }

    /// `mountIDs` に含まれる surface だけを ZStack で mount し、focusedID のみ
    /// opacity 1 で見せる。**同じ surface を 2 つの paneStack で mount しない**
    /// ことが libghostty NSView の identity を壊さない最重要条件。
    @ViewBuilder
    private func paneStack(mountIDs: [UUID], focusedID: UUID?) -> some View {
        ZStack {
            ForEach(mountIDs, id: \.self) { id in
                if let surface = appState.activeSurfaces[id] {
                    let show = id == focusedID
                    GhosttyTerminalView(
                        terminalSurface: surface,
                        isSelected: show,
                        onCloseRequested: { _ in
                            appState.handleSurfaceClosed(taskID: id)
                        }
                    )
                    .opacity(show ? 1 : 0)
                    .allowsHitTesting(show)
                } else if let surface = appState.shellSurfaces[id] {
                    let show = id == focusedID
                    GhosttyTerminalView(
                        terminalSurface: surface,
                        isSelected: show,
                        onCloseRequested: { _ in
                            appState.handleShellTabClosed(id: id)
                        }
                    )
                    .opacity(show ? 1 : 0)
                    .allowsHitTesting(show)
                }
            }
        }
    }

    // MARK: - Stage placeholder (Planning / Done)

    /// surface が無いステージでは terminal pane の代わりにステージ別の説明を出す。
    @ViewBuilder
    private func stagePlaceholder(for task: TaskCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch task.status {
                case .planning:
                    planningBody(for: task)
                case .done:
                    doneBody(for: task)
                case .review, .inProgress:
                    // resumeTask が非同期で走っている最中に一瞬だけ見える。
                    // `wt list` fallback を含めても数十 ms〜1 秒程度なので、
                    // 専用スピナーは入れず「復元中」だけ見せる。wt が無い /
                    // worktree が消えた等で resume 失敗した場合はこの表示で
                    // 留まる (lastError 側に silent fail している)。
                    Hand("claude セッションを復元中…", size: 14, color: WF.ink2)
                    Hand("worktree: \(task.branch)", size: 11, color: WF.ink3)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func planningBody(for task: TaskCard) -> some View {
        Hand("Claude prompt", size: 16, weight: .bold)
        Squiggle(width: 80)
        Text(task.body.isEmpty ? "(まだプロンプト未設定)" : task.body)
            .font(WFFont.mono(12))
            .foregroundStyle(WF.ink)
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sketchBox(fill: WF.paperAlt, radius: 8, shadow: false)

        if let needs = task.needs, !needs.isEmpty {
            Hand("Needs before start", size: 13, color: WF.ink2)
                .padding(.top, 4)
            HStack(spacing: 4) {
                ForEach(needs, id: \.self) { n in
                    WFPill(color: WF.ink3) { Text(n) }
                }
            }
        }

        HStack(spacing: 10) {
            Button {
                isStarting = true
                Task {
                    await appState.startTask(task)
                    isStarting = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isStarting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Hand(isStarting ? "Starting…" : "Start", size: 13, color: WF.paper)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(WF.ink, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(!canStart(task))
            .help(startHelpText(task))

            Button(role: .destructive) {
                appState.deleteTask(id: task.id)
                onClose()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                    Hand("Delete", size: 12, color: WF.pink)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(WF.pink.opacity(0.5), lineWidth: 1.2))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func doneBody(for task: TaskCard) -> some View {
        Hand("Shipped", size: 16, weight: .bold)
        Squiggle(width: 80)
        HStack(spacing: 20) {
            EvalMeter(score: task.evalScore, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                if let pr = task.pr {
                    Metric(label: "PR", value: pr, color: WF.accent)
                }
                if let merged = task.mergedAt {
                    Metric(label: "merged", value: merged)
                }
                Metric(label: "branch",
                       value: task.branch.replacingOccurrences(of: "kanbario/", with: ""))
            }
        }

        if !task.body.isEmpty {
            Hand("Original prompt", size: 13, color: WF.ink2).padding(.top, 8)
            Text(task.body)
                .font(WFFont.mono(12))
                .foregroundStyle(WF.ink2)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sketchBox(fill: WF.paperAlt, radius: 8, shadow: false)
        }
    }

    @ViewBuilder
    private func reviewNoTerminalBody(for task: TaskCard) -> some View {
        Hand("Review", size: 16, weight: .bold)
        Squiggle(width: 80)
        Hand("claude プロセスは既に終了済み", size: 12, color: WF.ink3)
        if !task.body.isEmpty {
            Text(task.body)
                .font(WFFont.mono(12))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sketchBox(fill: WF.paperAlt, radius: 8, shadow: false)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(for task: TaskCard) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                WFDot(color: hasAnyTerminal ? WF.done : WF.ink3, size: 7)
                Hand(hasAnyTerminal ? "shell connected" : "no session",
                     size: 11, color: WF.ink2)
            }
            if hasAnyTerminal {
                Text("pid \(String(format: "%05d", task.id.uuidString.hashValue & 0xFFFF))")
                    .font(WFFont.mono(10))
                    .foregroundStyle(WF.ink3)
            }
            Spacer()
            Hand(tabSummary, size: 11, color: WF.ink3)
                .padding(.trailing, 4)

            Button(role: .destructive) {
                appState.stopTask(id: task.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                    Hand("Stop", size: 11, color: WF.pink)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(Capsule().stroke(WF.pink.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(appState.activeSurfaces[task.id] == nil)
            .opacity(appState.activeSurfaces[task.id] == nil ? 0.35 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var tabSummary: String {
        let shells = appState.shellTabOrder.count
        let base = shells + (appState.selectedTaskID.flatMap { appState.activeSurfaces[$0] } != nil ? 1 : 0)
        if base == 0 { return "" }
        return "\(base) tab\(base > 1 ? "s" : "")" + (appState.isTerminalExpanded ? " · split view" : "")
    }

    // MARK: - Start gating

    private func canStart(_ task: TaskCard) -> Bool {
        task.status == .planning && appState.canStartTasks && !isStarting
    }

    private func startHelpText(_ task: TaskCard) -> String {
        if task.status != .planning { return "Only planning tasks can be started" }
        if !appState.canStartTasks { return "Choose a repository first (toolbar)" }
        if isStarting { return "Starting…" }
        return "Start Claude (wt switch + claude spawn)"
    }
}

// MARK: - Tab chip

private struct TabChip: View {
    let title: String
    let icon: String
    let isActive: Bool
    let showClose: Bool
    let onSelect: () -> Void
    let onClose: (() -> Void)?

    /// HStack 全体に `.onTapGesture` を付けると、内側の close Button よりも
    /// 先に親のジェスチャが hit を奪い close が発火しない。label 部分と close
    /// ボタンを兄弟 (どちらも独立した Button) として配置することで、close は
    /// 後から描かれた = 手前にあり、独立して hit-test される。
    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                        .foregroundStyle(isActive ? WF.ink : WF.ink2)
                    Text(title)
                        .font(WFFont.mono(11))
                        .foregroundStyle(isActive ? WF.ink : WF.ink2)
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showClose, let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(WF.ink3)
                        .padding(.horizontal, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 8, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 8,
                style: .continuous
            )
            .fill(isActive ? WF.paper : Color.clear)
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 8, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 8,
                style: .continuous
            )
            .stroke(isActive ? WF.line : Color.clear, lineWidth: 1)
        )
        .offset(y: 1)  // wireframe の「タブがわずかに下の border とつながる」効果
    }
}
