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

    // Delete 確認 alert の state は AppState.pendingDeleteConfirmation に
    // 統一 (ContentView 側で alert を 1 箇所にまとめて表示)。この View では
    // ローカルに保持しない — カード context menu 経由の削除フローと共通化
    // したいので app-level に置いた方が素直。

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

            // tab bar は planning / done では不要 (terminal を出さないので
            // 新規 shell タブを開いても意味がない)。inProgress / review
            // かつ terminal 実体がある時だけ表示する。
            if shouldShowTerminalArea {
                tabBar.background(WF.paperAlt)
                Divider().overlay(WF.line).opacity(0.6)
            }

            // ★ identity 維持の要: task 未選択でも panesArea は必ずマウントする。
            //   中身が空 (activeSurfaces / shellSurfaces がゼロ) でも ZStack は
            //   render コストほぼゼロ。逆に subtree を消すと PR #4 の罠を再現する。
            ZStack {
                panesArea
                    .opacity(shouldShowTerminalArea ? 1 : 0)
                    .allowsHitTesting(shouldShowTerminalArea)

                // planning / done or terminal 無しでは stage placeholder を表示。
                if let task = appState.selectedTask, !shouldShowTerminalArea {
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
        //
        // 併せて split 右ペインの選択 (`rightTerminalID`) も nil にリセット
        // する。shellTabOrderByTaskID はタスク単位になったので、前タスクの
        // shell ID を指したまま残すと「切替先タスクでは存在しない shell」
        // を右ペインにマウントしようとして panesArea が空になる。
        .onChange(of: appState.selectedTaskID) { _, newID in
            rightTerminalID = nil
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
                // task.id で識別して、選択中タスクが切り替わったら
                // InlineTitleField の @State draft がリセットされるようにする。
                InlineTitleField(task: task).id(task.id)
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
    ///      selectedTerminalIDByTaskID の entry を奪わないようにする
    private func primeRightTabIfNeeded() {
        guard rightTerminalID == nil else { return }
        if let firstDifferent = currentTaskShellIDs.first(where: { $0 != activeLeftID }) {
            rightTerminalID = firstDifferent
        } else {
            rightTerminalID = appState.openShellTab(selectAsLeftPane: false)
        }
    }

    /// shell が libghostty に close を要請した瞬間 (`exit` 投入 / タブの ×)
    /// に、分割の pane 割当を先回りで整える。
    ///
    /// `handleShellTabClosed` が触るのは AppState 側の共有 state (shellSurfaces /
    /// shellTabOrderByTaskID / selectedTerminalIDByTaskID) だけ。分割モード
    /// 自体 (`isTerminalExpanded`) と右ペインの mount 対象 (`rightTerminalID`,
    /// TaskDetailView の `@State`) は view が自分で面倒を見る必要があるので、
    /// ここでまとめて次のどちらかに落とす:
    ///
    /// 1. 閉じるのが **右ペインの shell** で、残りに左と被らない別 shell が
    ///    あれば繰り上げ。無ければ split 自体を解除 (divider だけ残った
    ///    empty 右ペインを作らない — これが元の symptom の根本原因)。
    /// 2. 閉じるのが **左ペインの shell** で、`handleShellTabClosed` の再割り
    ///    当て候補 (= 残り order の末尾) が `rightTerminalID` と衝突しそうな
    ///    時も、右を別 shell に差し替え or split を解除する。同じ surface が
    ///    左右 2 重 mount されると libghostty の NSView attach が後勝ちで
    ///    入力が通らなくなる。
    @MainActor
    private func reconcileSplitOnShellClose(closingID: UUID) {
        guard appState.isTerminalExpanded else { return }
        let remaining = currentTaskShellIDs.filter { $0 != closingID }
        let leftID = activeLeftID

        // Case 1: 右ペインの shell が閉じる。
        if rightTerminalID == closingID {
            if let next = remaining.first(where: { $0 != leftID }) {
                rightTerminalID = next
            } else {
                rightTerminalID = nil
                appState.isTerminalExpanded = false
            }
            return
        }

        // Case 2: 左ペインの shell が閉じ、handleShellTabClosed が
        // `rightTerminalID` と同じ shell を左ペインに繰り上げようとする衝突。
        // handleShellTabClosed の再割当ルールは「直前のタブ or 末尾 or claude」
        // なので、閉じる shell の直前の候補を予測する。
        guard let ownerTID = appState.selectedTaskID,
              appState.selectedTerminalIDByTaskID[ownerTID] == closingID else {
            return
        }
        let fullOrder = appState.shellTabOrderByTaskID[ownerTID] ?? []
        let removedIdx = fullOrder.firstIndex(of: closingID)
        let projectedLeft: UUID?
        if let idx = removedIdx, idx > 0 {
            projectedLeft = remaining.indices.contains(idx - 1) ? remaining[idx - 1] : nil
        } else {
            projectedLeft = remaining.last
        }
        guard projectedLeft == rightTerminalID else { return }

        // 右を別 shell に回す (左候補とも違うもの) か、候補が無ければ split 解除。
        if let candidate = remaining.first(where: { $0 != projectedLeft }) {
            rightTerminalID = candidate
        } else {
            rightTerminalID = nil
            appState.isTerminalExpanded = false
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
                   value: task.displayBranch,
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

    /// 現在選択中のタスクが所有する shell tab の並び (空なら空配列)。
    /// tabBar / footer / split toggle など「選択中タスクだけに閉じた UI」の
    /// 単一 source of truth。
    private var currentTaskShellIDs: [UUID] {
        guard let id = appState.selectedTaskID else { return [] }
        return appState.shellTabOrderByTaskID[id] ?? []
    }

    private var hasAnyTerminal: Bool {
        guard let id = appState.selectedTaskID else { return false }
        if appState.activeSurfaces[id] != nil { return true }
        return !currentTaskShellIDs.isEmpty
    }

    /// terminal エリア (tab bar + panes) を可視化するかの判定。
    ///
    /// planning / done のタスクでは agent セッションは存在しない or 既に
    /// 終了済みなので、shell エリアを出す意味が薄い (shell タブは開けるが
    /// UI を圧迫するだけ)。これらのステージでは terminal を隠して
    /// planningBody / doneBody の編集 UI / メタ情報だけを全面表示する。
    /// QA は review と同じ扱い — agent を resume して動かし直せる状態なので
    /// terminal を出す。
    private var shouldShowTerminalArea: Bool {
        guard let task = appState.selectedTask else { return false }
        if task.status == .planning || task.status == .done { return false }
        return hasAnyTerminal
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            // Agent タブ (アクティブな task surface があれば)
            if let id = appState.selectedTaskID,
               appState.activeSurfaces[id] != nil,
               let task = appState.tasks.first(where: { $0.id == id }) {
                TabChip(
                    title: task.title,
                    icon: task.agentKind.terminalIcon,
                    isActive: activeLeftID == id,
                    showClose: false,
                    onSelect: {
                        // entry 削除 = 「選択中 task の claude を見る」既定状態。
                        appState.selectedTerminalIDByTaskID.removeValue(forKey: id)
                    },
                    onClose: nil
                )
            }
            ForEach(Array(currentTaskShellIDs.enumerated()), id: \.element) { index, shellID in
                TabChip(
                    title: "zsh #\(index + 1)",
                    icon: "chevron.left.forwardslash.chevron.right",
                    isActive: activeLeftID == shellID,
                    showClose: true,
                    onSelect: {
                        guard let tid = appState.selectedTaskID else { return }
                        appState.selectedTerminalIDByTaskID[tid] = shellID
                    },
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
    /// 選択中 task の entry に shell が指定されていればそれ、そうでなければ
    /// claude surface (= task ID)。
    private var activeLeftID: UUID? {
        guard let tid = appState.selectedTaskID else { return nil }
        if let shell = appState.selectedTerminalIDByTaskID[tid],
           appState.shellSurfaces[shell] != nil {
            return shell
        }
        return tid
    }

    /// 左右ペインに mount する surface ID を排他に配分する。
    /// libghostty の `TerminalSurface` は NSView 1 つと寿命を共有するため、
    /// 同一 surface を 2 ペインで mount すると attach が後勝ちになって
    /// 先に attach した側の入力が通らなくなる。split 時は rightTerminalID を
    /// 右ペイン「だけ」に配り、左ペインは残り全て、と明確に分離する。
    ///
    /// **Defense-in-depth:** `rightTerminalID` が生きている shell を指している
    /// かを `shellSurfaces` で検証してから split を決める。`onCloseRequested`
    /// の reconciliation で普段は先回りで掃除しているが、まだ発火していない
    /// フレーム / 何らかの経路で surface が消えた場合に「divider だけ残った
    /// 空の右ペイン」が出ないようにする保険。
    private var panesArea: some View {
        let effectiveRightID: UUID? = {
            guard appState.isTerminalExpanded,
                  let id = rightTerminalID,
                  appState.shellSurfaces[id] != nil else { return nil }
            return id
        }()
        let split = effectiveRightID != nil
        let rightID = effectiveRightID
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

    /// 全 surface (全タスクの claude + 全タスクの shell) の ID を並び順を
    /// 保って返す。`paneStack` はこのリストから割り当て先を絞り込んで mount
    /// する。
    ///
    /// **重要:** tabBar は現在 task の shell だけに絞るが、ZStack に mount
    /// する surface は**全タスクの shell**を含める。これは libghostty の
    /// NSView が ZStack から一旦外れると SIGHUP で子プロセスが殺される
    /// ため (cmux の罠と同じ)。他タスクに切り替えている間も shell を殺さず
    /// に温存しておくことで、戻ってきた時にそのまま作業を続けられる。
    private var allSurfaceIDs: [UUID] {
        var ids: [UUID] = []
        // task 側は tasks 配列の順で (Dictionary は順序非保持なので、常に
        // 決定的な順序に正規化するために明示ループ)
        for task in appState.tasks where appState.activeSurfaces[task.id] != nil {
            ids.append(task.id)
        }
        // 全タスクの shell tabs も同じく決定的順序で (arrays 側で並びを
        // 管理しているので enumerate は辞書の UUID ソート順依存にせず、
        // tasks 配列順 → その task の shell 配列順、と層化する)。
        for task in appState.tasks {
            if let order = appState.shellTabOrderByTaskID[task.id] {
                ids.append(contentsOf: order)
            }
        }
        return ids
    }

    /// 右ペインの inner tab bar。左ペインと同じ shell を右にアサインすると
    /// libghostty が二重 attach で壊れるため、activeLeftID に一致するタブは
    /// リストから除外 (右で使いたければ、まず左で別タブに切り替えてから選ぶ)。
    private var rightPaneTabBar: some View {
        let candidates = currentTaskShellIDs.enumerated().filter { _, id in id != activeLeftID }
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
                            // split ペインの割当を先回りで整えてから AppState に
                            // teardown を任せる。順番が逆だと、`handleShellTabClosed`
                            // 実行直後の 1 frame だけ「rightTerminalID は dead UUID /
                            // isTerminalExpanded は true」の不整合状態が出て、
                            // divider + 空の右ペインがちらつく。
                            reconcileSplitOnShellClose(closingID: id)
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
                case .review, .inProgress, .qa:
                    // resumeTask が非同期で走っている最中に一瞬だけ見える。
                    // `wt list` fallback を含めても数十 ms〜1 秒程度なので、
                    // 専用スピナーは入れず「復元中」だけ見せる。wt が無い /
                    // worktree が消えた等で resume 失敗した場合はこの表示で
                    // 留まる (lastError 側に silent fail している)。
                    Hand("\(task.agentKind.displayName) セッションを復元中…", size: 14, color: WF.ink2)
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
        // planning ステージ専用の編集パネル。task.id で識別して、
        // 選択中タスクが切り替わったら draft がリセットされるようにする。
        PlanningEditorFields(task: task).id(task.id)

        if let needs = task.needs, !needs.isEmpty {
            Hand("Needs before start", size: 13, color: WF.ink2)
                .padding(.top, 4)
            HStack(spacing: 4) {
                ForEach(needs, id: \.self) { n in
                    WFPill(color: WF.ink3) { Text(n) }
                }
            }
        }

        VStack(alignment: .leading, spacing: 6) {
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

                deleteButton(for: task)
            }

            // Start 中は wt / hook の最新行を小さく表示して「今なにが走っているか」
            // をユーザーに見せる。bun install / uv sync 等の実行中、固まっているの
            // ではないことが分かる。非表示時は .empty で高さを占有しないように。
            if let progress = appState.startProgressByTaskID[task.id] {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(WF.ink3)
                    Text(progress)
                        .font(WFFont.mono(10))
                        .foregroundStyle(WF.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .transition(.opacity)
            }
        }
        .padding(.top, 6)
    }

    /// 全 stage で使い回す削除ボタン。Delete は worktree remove と surface
    /// teardown を伴うため async。dirty worktree の場合は確認 alert を
    /// 挟んでから実行する (誤削除で uncommitted change を失う事故を防ぐ)。
    ///
    /// 処理中 (`appState.deletingTaskIDs.contains(task.id)`) は spinner +
    /// 「Deleting…」ラベル + disable。`wt remove` + surface teardown で
    /// 1 秒〜数秒かかることがあり、ここでフィードバックを返さないと
    /// ユーザーは「クリックが効かなかった」と誤認する。
    @ViewBuilder
    private func deleteButton(for task: TaskCard) -> some View {
        let isDeleting = appState.deletingTaskIDs.contains(task.id)
        Button(role: .destructive) {
            Task { await requestDelete(task: task) }
        } label: {
            HStack(spacing: 4) {
                if isDeleting {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                    Hand("Deleting…", size: 12, color: WF.pink)
                } else {
                    Image(systemName: "trash")
                    Hand("Delete", size: 12, color: WF.pink)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(WF.pink.opacity(0.5), lineWidth: 1.2))
        }
        .buttonStyle(.plain)
        .disabled(isDeleting)
        .opacity(isDeleting ? 0.6 : 1)
    }

    /// Delete ボタン押下時のエントリ。dirty 判定と実行は
    /// `AppState.requestDelete` に委譲。clean ならそのまま削除が走るので
    /// モーダルは即閉じる。dirty なら pendingDeleteConfirmation が立って
    /// ContentView の alert が出る — alert の「削除する」から完遂するので
    /// この時点ではモーダルを閉じない (閉じると alert が dismiss してしまう
    /// 可能性があるため、ContentView 側の alert handler でクローズする)。
    @MainActor
    private func requestDelete(task: TaskCard) async {
        let hadDirty = await appState.checkWorktreeDirty(task: task) != nil
        if !hadDirty {
            onClose()
        }
        await appState.requestDelete(id: task.id)
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
                       value: task.displayBranch)
            }
        }

        if !task.body.isEmpty {
            Hand("Original prompt", size: 13, color: WF.ink2).padding(.top, 8)
            Text(task.body)
                .font(WFFont.mono(12))
                .foregroundStyle(WF.ink2)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sketchBox(fill: WF.paperAlt, radius: 8, shadow: false)
        }

        deleteButton(for: task)
            .padding(.top, 8)
    }

    @ViewBuilder
    private func reviewNoTerminalBody(for task: TaskCard) -> some View {
        Hand("Review", size: 16, weight: .bold)
        Squiggle(width: 80)
        Hand("\(task.agentKind.displayName) プロセスは既に終了済み", size: 12, color: WF.ink3)
        if !task.body.isEmpty {
            Text(task.body)
                .font(WFFont.mono(12))
                .textSelection(.enabled)
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
        let shells = currentTaskShellIDs.count
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
        return "Start \(task.agentKind.displayName) (wt switch + \(task.agentKind.executableName) spawn)"
    }
}

// MARK: - InlineTitleField

/// タスクタイトルを title bar 内で直接編集できる小さな TextField。
///
/// **設計意図:**
/// - 全ステージ (planning/inProgress/review/done) で編集可能 — ユーザーが
///   タスク名を後から整理したくなるのは自然な運用。
/// - 見た目は元の Hand (handwriting bold) と揃えて、外側の枠や背景を付けない
///   plain スタイル。既存 UI から「普通のテキスト」と区別がつかない自然さが
///   inline edit の要点。
/// - 親 view は `.id(task.id)` を付与してタスク切替時に @State をリセットする。
fileprivate struct InlineTitleField: View {
    @Environment(AppState.self) private var appState
    let task: TaskCard
    @State private var draft: String

    init(task: TaskCard) {
        self.task = task
        // **重要:** @State の初期値は init で注入する。onAppear で代入する
        // 旧実装だと "" → task.title の変化が onChange を発火させ、
        // updateTitle が updatedAt を書き換え、tasks(in:) の並び順が狂う
        // (ユーザーが「カードを選ぶたびに順番が変わる」と感じる原因)。
        _draft = State(initialValue: task.title)
    }

    var body: some View {
        TextField("", text: $draft, prompt: Text("Title"))
            .textFieldStyle(.plain)
            .font(WFFont.hand(15, weight: .bold))
            .foregroundStyle(WF.ink)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: draft) { _, new in
                // init で初期化済のため通常の初回発火は起きないが、
                // SwiftUI 再描画経路での冗長発火を念のため等価チェックで弾く。
                // これで「編集していないのに updatedAt が更新される」事故を
                // 完全に防げる。
                if new == task.title { return }
                appState.updateTitle(id: task.id, title: new)
            }
    }
}

// MARK: - PlanningEditorFields

/// planning ステージ限定の prompt / branch 編集パネル。Claude が起動する前
/// なので、ここでの書き換えは worktree 整合性と衝突しない。
/// 入力イベントごとに appState.updateBody / updateBranch を叩いて永続化する
/// (debounce なし — macOS の atomic write はサイズ小なら十分速い)。
fileprivate struct PlanningEditorFields: View {
    @Environment(AppState.self) private var appState
    let task: TaskCard
    @State private var bodyDraft: String
    @State private var branchDraft: String
    @State private var agentDraft: AgentKind

    init(task: TaskCard) {
        self.task = task
        // **重要:** @State を init で直接注入。onAppear による遅延代入は
        // 変化として onChange を発火させ、updateBody / updateBranch 経由で
        // updatedAt を書き換えてカード並び順を乱す。
        _bodyDraft = State(initialValue: task.body)
        _branchDraft = State(initialValue: task.branch)
        _agentDraft = State(initialValue: task.agentKind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            agentBlock
            promptBlock
            branchBlock
        }
    }

    @ViewBuilder
    private var agentBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Hand("Agent", size: 12, color: WF.ink2)
            Picker("", selection: $agentDraft) {
                ForEach(AgentKind.allCases) { agent in
                    Text(agent.displayName).tag(agent)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .onChange(of: agentDraft) { _, new in
                appState.updateAgent(id: task.id, agent: new)
            }
        }
    }

    @ViewBuilder
    private var promptBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Hand(agentDraft.promptLabel, size: 16, weight: .bold)
            Squiggle(width: 80)
            TextEditor(text: $bodyDraft)
                .font(WFFont.mono(12))
                .foregroundStyle(WF.ink)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(WF.paperAlt)
                .frame(minHeight: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(WF.line, lineWidth: 1.3)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: bodyDraft) { _, new in
                    // 冗長発火ガード (並び順保護)
                    if new == task.body { return }
                    appState.updateBody(id: task.id, body: new)
                }
        }
    }

    @ViewBuilder
    private var branchBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Hand("Branch", size: 12, color: WF.ink2)
            TextField("kanbario/...", text: $branchDraft)
                .textFieldStyle(.plain)
                .font(WFFont.mono(12))
                .foregroundStyle(WF.ink)
                .padding(8)
                .background(WF.paperAlt, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(WF.line, lineWidth: 1.2)
                )
                .onChange(of: branchDraft) { _, new in
                    // 冗長発火ガード (並び順保護)
                    if new == task.branch { return }
                    appState.updateBranch(id: task.id, branch: new)
                }
        }
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
