import Foundation
import Observation
import UserNotifications
import AppKit   // NotificationService の click handler で NSApp.activate / windows を叩くため

/// アプリ全体のルート状態。SwiftUI View から `@Environment(AppState.self)` で参照。
///
/// 永続化: `tasks` と `repoPath` を JSON にして
/// `~/Library/Application Support/kanbario/state.json` に書く。
/// GRDB の導入は Commit 2 (hook 統合) で event log が必要になった時点で行う。
@Observable
final class AppState {
    /// 表示中の全タスク。カラム分けは `tasks(in:)` で取得。
    var tasks: [TaskCard] = []

    /// 詳細画面に表示中のタスク。nil なら詳細なし。
    var selectedTaskID: UUID?

    /// 現在 drag 中のタスク ID。drag 開始時に set、drop または timeout で nil に戻る。
    /// UI 側で source card を opacity 0 にするのに使う。
    var draggingTaskID: UUID?

    /// 選択中のリポジトリのパス (空 = 未設定)。Start ボタンを有効化する前提。
    var repoPath: String = ""

    /// UI に表示するエラー (alert の source of truth)。
    var lastError: String?

    /// 現在 live な claude セッション: taskID -> TerminalSurface (libghostty が
    /// PTY と子プロセスを所有する。Milestone D 以降はここで保持するだけで、
    /// stdout の吸い出し・ログ蓄積はやらない — libghostty が GPU に描画する)。
    var activeSurfaces: [UUID: TerminalSurface] = [:]

    /// Claude hook で受け取った活動状態。surface が消えれば nil に戻す。
    /// 詳細画面のバッジ表示用 (Models.swift の `ClaudeActivity` 参照)。
    var activitiesByTaskID: [UUID: ClaudeActivity] = [:]

    /// true の間は選択中タスクの terminal を全画面モーダル相当で表示する。
    /// 実装は ZStack で frame を拡大するだけなので、NSView identity は不変で
    /// claude は殺されない (terminalArea のコメント参照)。
    var isTerminalExpanded: Bool = false

    /// expanded 中に ⌘T で開く「普通のシェル」タブ。**タスク単位に所有**
    /// されていて、タスクを切り替えると他タスクの shell tab は tabBar から
    /// 消える (cwd が worktree に紐づく設計なので、他タスクの shell を別
    /// タスクのタブバーに混ぜると意味論が壊れる)。
    ///
    /// - `shellSurfaces`: shell UUID → surface (identity 維持のため全 shell
    ///   surface を ZStack にマウントし続ける都合で**グローバル辞書のまま**
    ///   保持する。unmount すると libghostty が SIGHUP を送って shell が死ぬ)
    /// - `shellTabOrderByTaskID`: タスク単位のタブ並び順。tabBar はこれを読む
    /// - `shellOwnerByID`: shell UUID → オーナー task UUID (close 時の逆引き用)
    var shellSurfaces: [UUID: TerminalSurface] = [:]
    var shellTabOrderByTaskID: [UUID: [UUID]] = [:]
    var shellOwnerByID: [UUID: UUID] = [:]

    /// Project Shell Window で開かれる「タスクと無関係な shell」群。
    /// cwd は常に `repoPath` (無ければ HOME)。task の worktree とは切り離され、
    /// 単に「プロジェクトの大元で作業したい時のための別ウィンドウ」として
    /// 機能する。Window scene は singleton なので、複数タブで増やす時の
    /// ID 並びは `projectShellTabOrder` に保持する。
    var projectShellSurfaces: [UUID: TerminalSurface] = [:]
    var projectShellTabOrder: [UUID] = []
    var selectedProjectShellID: UUID?

    /// Start 時に wt が作成した worktree の絶対パスを taskID ごとに保持する。
    /// 新規 shell タブの cwd をそのタスクの worktree に合わせるために使う
    /// (main repo root ではなく、その claude が作業している worktree で shell を
    /// 開く方が「tab を増やして脇で git log や rg したい」という実利用に合う)。
    /// tasks と違って永続化しない — surface が live な間だけ意味がある。
    var worktreeURLByTaskID: [UUID: URL] = [:]

    /// Claude transcript JSONL から抽出した live log。taskID ごとに最新 50 件まで
    /// 保持。カード UI は末尾 3-5 件を mono font で表示する。永続化はしない
    /// (transcript ファイル自体が source of truth、アプリ再起動時は session-start
    /// hook 再到着を待って再 tail する)。
    var activityLog: [UUID: [TranscriptTailer.LogEntry]] = [:]

    /// Claude の「今動いている感」をカードに表示するための状態。TodoWrite の
    /// todos / 最新 tool_use と未解決 tool_use_id / turn 開始時刻を保持する。
    /// 永続化しない (live data)。
    var currentActivityByTaskID: [UUID: CurrentActivity] = [:]

    /// Notification hook が「permission 要求中」を示した時にそのメッセージを
    /// 保持する。UserPromptSubmit / PreToolUse / Stop / SessionEnd 等、
    /// 「何らかの次アクション」が起きた時点で自動クリアする。カード上に
    /// 赤バッジ + tooltip で詳細を見せるため、永続化しない。
    var pendingPermissionByTaskID: [UUID: String] = [:]

    /// NewTaskSheet の表示 state を AppState 側に持つ source of truth。
    /// App レベルの `.commands` (⌘N) からも ContentView からも一貫して
    /// 触れるようにするため。
    var showingNewTaskSheet: Bool = false

    /// Start 中のタスクに対して「今なにが走っているか」を最新 1 行で保持する。
    /// wt list / hook の stdout を line 単位で流し込み、完了したら nil に戻す。
    /// UI は Start ボタン横に小さく表示する。
    var startProgressByTaskID: [UUID: String] = [:]

    /// claude を auto mode (= permission prompt を全スキップ) で起動するか。
    /// デフォルト ON (kanbario 内で動かす前提、承認プロンプトで止まる UX を
    /// 避ける)。将来 toolbar の toggle / タスク単位の設定に昇格可能。
    var autoModeEnabled: Bool = true

    /// deleteTask が走っている最中のタスク ID 集合。UI はこれを読んで
    /// spinner / disable / opacity 低下などで「削除処理中」を可視化する。
    /// deleteTask 内で insert → defer remove するので、例外や途中 cancel
    /// でも取りこぼさない。
    var deletingTaskIDs: Set<UUID> = []

    /// resumeTask 実行中の ID 集合。UI がカードに「復元中」バッジを出し、
    /// 並列 resume 経路と TaskDetailView.onChange 経路の二重起動も抑止する。
    /// 起動時 auto-resume + ユーザー操作 resume の両方で同じ state を読む。
    var resumingTaskIDs: Set<UUID> = []

    /// 進行中の startTask を cancel できるよう、taskID → wrapping Task を
    /// 保持する。ユーザーが Starting カード上で × を押したら
    /// `cancelStart(id:)` がここから Task を取り出して `.cancel()` を呼び、
    /// wt subprocess が SIGTERM で止まる → WorktreeService.run が
    /// CancellationError を throw → startTask の catch 節で silent 終了。
    private var startTaskTasks: [UUID: Task<Void, Never>] = [:]

    /// dirty worktree に対する削除リクエストの保留情報。モーダル / カード
    /// のどこから削除 UI を起動しても同じ確認 alert (ContentView 側で
    /// observe) を通すために app-level に置く。非 nil の間は
    /// `confirmPendingDelete` / `cancelPendingDelete` のどちらかで解消する。
    var pendingDeleteConfirmation: PendingDeleteConfirmation?

    struct PendingDeleteConfirmation: Equatable {
        let taskID: UUID
        /// alert メッセージ用の短い表示名 (worktree dir の lastPathComponent)。
        let worktreeDirName: String
    }

    /// taskID → 稼働中の TranscriptTailer。session-start で起動、
    /// session-end / performCleanup / handleSurfaceClosed で停止する。
    private var transcriptTailers: [UUID: TranscriptTailer] = [:]

    /// タスク単位で「今左ペインに表示すべき shell surface」の ID を保持する
    /// 辞書。キー = タスク ID、値 = shell UUID。
    ///
    /// - entry 無し: そのタスクの claude surface を左ペインに見せる (既定)
    /// - entry あり かつ shellSurfaces にある: その shell を左ペインに見せる
    ///
    /// タスク切替で自動的に切替先の entry を読むので、「前のタスクで選んで
    /// いた shell が次のタスクでも開きっぱなしに見える」事故が発生しない。
    var selectedTerminalIDByTaskID: [UUID: UUID] = [:]

    /// デモ用のデフォルトプロジェクト。MVP は 1 プロジェクト前提。
    let defaultProject: Project

    /// repoPath が設定されるまでは nil。設定時に init (throws)、失敗時は lastError を立てる。
    private(set) var worktreeService: WorktreeService?

    /// 永続化先 (テストから差し替え可能)。
    private let saveURL: URL

    /// Claude CLI からの hook を Unix socket で受ける常駐 listener。
    /// init で立ち上がり、deinit で stop する。
    private var hookReceiver: HookReceiver?

    init(saveURL: URL? = nil) {
        self.saveURL = saveURL ?? Self.defaultSaveURL()
        self.defaultProject = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Kanbario",
            repoPath: "",
            defaultBranch: "main",
            createdAt: Date()
        )
        if let loaded = Self.load(from: self.saveURL) {
            self.tasks = loaded.tasks
            self.repoPath = loaded.repoPath
            // worktree path cache を復元。stale path (ユーザーが手動削除した
            // worktree) が混ざっている可能性はあるが、resumeTask 側で実在
            // チェック → wt list fallback するので致命的ではない。
            for (idStr, path) in loaded.worktreeURLByTaskID {
                if let id = UUID(uuidString: idStr) {
                    self.worktreeURLByTaskID[id] = URL(fileURLWithPath: path)
                }
            }
        }
        // repoPath が生きていれば WorktreeService を立ち上げる。起動時に
        // wt バイナリが PATH から消えている可能性を握りつぶしたくないので
        // 失敗したら lastError に流して UI に見せる。
        if !repoPath.isEmpty {
            configureWorktreeService()
        }
        startHookReceiver()
        // Notification click → task 選択の経路を繋ぐ。delegate 設定は
        // requestAuthorization より前に済ませておく必要はないが、副作用を
        // 1 箇所に集約するために隣接させている。
        NotificationService.shared.configure(appState: self)
        NotificationService.shared.requestAuthorizationIfNeeded()

        // 起動時に「前回セッションが live のまま閉じられた」タスクを自動で
        // resume する。init は同期的でここで await できないので Task で
        // 背景投入 (UI は即描画しつつ、裏で並列に claude --continue が走る)。
        // resumeTask 側で resumingTaskIDs を立てるので、ボードの各カードに
        // "Resuming" バッジが出て「裏で復元している」ことが目視できる。
        Task { [weak self] in
            await self?.restoreActiveSessionsAtLaunch()
        }
    }

    deinit {
        hookReceiver?.stop()
    }

    // MARK: - Queries

    /// 指定カラムに属するタスクを、更新日の新しい順で返す。
    func tasks(in status: TaskStatus) -> [TaskCard] {
        tasks
            .filter { $0.status == status }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 選択中のタスク (無ければ nil)。
    var selectedTask: TaskCard? {
        guard let id = selectedTaskID else { return nil }
        return tasks.first(where: { $0.id == id })
    }

    /// drag 中のタスク (無ければ nil)。drop 先 column のゴーストカード表示に使う。
    var draggingTask: TaskCard? {
        guard let id = draggingTaskID else { return nil }
        return tasks.first(where: { $0.id == id })
    }

    /// Start ボタンを有効化できる状態か。
    var canStartTasks: Bool { worktreeService != nil }

    // MARK: - Mutations

    /// 新規タスクを planning 列に追加する。LLM メタ (tag / risk / owner / promptV /
    /// needs) はデザイン wireframe の planning ステージカード相当で任意入力。
    ///
    /// **Branch 名の決定:**
    /// - `branch` 引数が与えられたらそれをそのまま使う (フォームでユーザーが
    ///   入力した値、または ✨ AI ボタンで LLM 生成した値が渡ってくる)。
    /// - nil / 空の場合は uuid ベースの `feature/<uuid6>` を fallback として
    ///   使う (以前の `kanbario/` プレフィックスは旧版互換のため
    ///   `TaskCard.displayBranch` で剥がされるが、新規はすべて `feature/`)。
    ///
    /// **Title の決定:** 空欄 OK。空なら body の先頭 10 文字 (grapheme cluster
    /// 単位) を title に採用 → 日本語 prompt も「最初の 10 文字」を素直に取れる。
    /// 10 文字超過時は末尾に `…` を付けて省略を示す。body も空なら `(Untitled)`。
    func addTask(
        title: String,
        body: String,
        branch: String? = nil,
        tag: LLMTag? = nil,
        risk: RiskLevel? = nil,
        owner: String? = nil,
        promptV: String? = nil,
        needs: [String]? = nil
    ) {
        let id = UUID()
        let now = Date()
        let resolvedBranch: String = {
            if let b = branch?.trimmingCharacters(in: .whitespacesAndNewlines),
               !b.isEmpty {
                return b
            }
            return "feature/\(id.uuidString.prefix(6).lowercased())"
        }()
        let resolvedTitle = Self.resolveTitle(explicitTitle: title, body: body)
        let task = TaskCard(
            id: id,
            projectID: defaultProject.id,
            title: resolvedTitle,
            body: body,
            status: .planning,
            branch: resolvedBranch,
            createdAt: now,
            updatedAt: now,
            tag: tag,
            risk: risk,
            promptV: promptV,
            owner: owner,
            needs: (needs?.isEmpty ?? true) ? nil : needs
        )
        tasks.append(task)
        save()
    }

    /// title が空 / 空白のみなら body の先頭 10 文字 (+ `…` if 長い) を title に。
    /// body も空なら "(Untitled)"。改行は 1 つの空白に正規化して「1 行見出し」に。
    fileprivate static func resolveTitle(explicitTitle: String, body: String) -> String {
        let trimmed = explicitTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let normalizedBody = body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if normalizedBody.isEmpty { return "(Untitled)" }
        let head = normalizedBody.prefix(10)
        return String(head) + (normalizedBody.count > 10 ? "…" : "")
    }

    /// title は全ステージで編集可能にする (ユーザーがタスク名を後から
    /// 整理する運用を想定)。空文字もそのまま許容するが、表示側は title
    /// 空なら body の先頭から近似するのが筋 — ここでは与えられた値を素直に保存。
    func updateTitle(id: UUID, title: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空にされた場合は body からの fallback で再計算する (UX 上、空文字で
        // 保存しておくよりは「自動生成」に戻った方が自然)。
        tasks[idx].title = trimmed.isEmpty
            ? Self.resolveTitle(explicitTitle: "", body: tasks[idx].body)
            : trimmed
        tasks[idx].updatedAt = Date()
        save()
    }

    /// prompt (body) は **planning ステージ限定**で編集可能。inProgress 以降は
    /// worktree に claude が起動しているので、kanbario 側の記憶だけ書き換えても
    /// claude セッションの会話履歴とは切り離される。ユーザーが混乱するので
    /// planning 以外では no-op。
    func updateBody(id: UUID, body: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[idx].status == .planning else { return }
        tasks[idx].body = body
        tasks[idx].updatedAt = Date()
        save()
    }

    /// branch も **planning ステージ限定**。worktree 作成後に書き換えると
    /// wt remove の名前解決が狂うため。空文字の書き換えは無視 (= 以前の値維持)。
    func updateBranch(id: UUID, branch: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[idx].status == .planning else { return }
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tasks[idx].branch = trimmed
        tasks[idx].updatedAt = Date()
        save()
    }

    /// タスクのステータスを変更する。
    ///
    /// **drag 特別処理 (planning → inProgress):** drag で inProgress 列に
    /// 落としたケースを Start ボタン押下と同等に扱う。status を直接
    /// `inProgress` には書き換えず、`startTask` を async で走らせて
    /// wt create + claude spawn を実行する。成功時は startTask 内部の
    /// applyStatus で inProgress に遷移、失敗時は planning のまま残って
    /// lastError alert が上がる (UX 上「drag したら inProgress 列に動い
    /// ているのに terminal が無い」という中途半端状態を避ける)。
    ///
    /// **review → done:** worktree cleanup + claude kill が要るので async 分岐。
    /// それ以外 (review ↔ inProgress 等) は同期書き換え。
    func moveTask(id: UUID, to newStatus: TaskStatus) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        let current = tasks[idx].status
        guard current.canTransition(to: newStatus) else { return }

        if current == .planning && newStatus == .inProgress {
            let taskSnapshot = tasks[idx]
            Task { await self.startTask(taskSnapshot) }
            return
        }

        if (current == .review || current == .qa) && newStatus == .done {
            // QA からも review からも done は物理 cleanup を伴うので同じ経路
            // (QA は review と扱いが同じというユーザー要求通り)。
            let taskSnapshot = tasks[idx]
            Task { await self.moveToDone(task: taskSnapshot) }
            return
        }

        tasks[idx].status = newStatus
        tasks[idx].updatedAt = Date()
        save()
    }

    /// 削除操作の前に task の worktree に未コミット変更があるか確かめる。
    /// - 戻り値が URL → dirty (未コミット変更あり)。UI は確認 alert を出す。
    /// - 戻り値が nil → clean or worktree 不在 (planning ステージ等)。即削除 OK。
    ///
    /// worktree URL の解決は ephemeral cache → wt list の 2 段 fallback。
    /// アプリ再起動後は cache が空なので wt list から引く。
    func checkWorktreeDirty(task: TaskCard) async -> URL? {
        guard let wt = worktreeService else { return nil }
        let worktreeURL: URL
        if let cached = worktreeURLByTaskID[task.id] {
            worktreeURL = cached
        } else if let all = try? await wt.list(),
                  let found = all.first(where: { $0.branch == task.branch }) {
            worktreeURL = URL(fileURLWithPath: found.path)
        } else {
            // worktree 自体が無い (planning or 既に削除済) → dirty 判定不要。
            return nil
        }
        return await wt.isDirty(worktreePath: worktreeURL) ? worktreeURL : nil
    }

    /// タスクを削除する。アーカイブ的な操作 (Done 経由ではない廃棄) も同じ経路。
    /// ステージに関わらず surface teardown + wt remove を試みてから tasks から除く。
    /// planning は worktree 未作成・surface 無しなので no-op で素通り、
    /// done は wt remove を既に実行済だが冪等 (branch が無ければ wt が NO-OP 相当)。
    /// UI から「削除したい」と言われた時のエントリーポイント。カード
    /// contextMenu でもモーダルの Delete ボタンでも共通に呼ばれる。
    /// dirty な worktree があれば `pendingDeleteConfirmation` を立てて
    /// ContentView 側の alert に委ねる。clean なら即 `deleteTask` を
    /// async で走らせる。
    func requestDelete(id: UUID) async {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        guard !deletingTaskIDs.contains(id) else { return }
        if let dirtyURL = await checkWorktreeDirty(task: task) {
            pendingDeleteConfirmation = PendingDeleteConfirmation(
                taskID: id,
                worktreeDirName: dirtyURL.lastPathComponent
            )
        } else {
            await deleteTask(id: id)
        }
    }

    /// ContentView の alert の「削除する」ボタンから呼ばれる。
    /// pending を解除してから deleteTask を走らせる順序は重要 —
    /// alert の dismiss 中に別 alert が立ち上がる race を避けるため。
    func confirmPendingDelete() async {
        guard let p = pendingDeleteConfirmation else { return }
        pendingDeleteConfirmation = nil
        await deleteTask(id: p.taskID)
    }

    func cancelPendingDelete() {
        pendingDeleteConfirmation = nil
    }

    func deleteTask(id: UUID) async {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        // 多重クリックや重複呼び出しを抑止しつつ、UI の「削除中…」表示を
        // 支える。defer で必ず除去 (performCleanup が throw しない設計だが、
        // 将来変わっても取りこぼさない保険)。
        guard !deletingTaskIDs.contains(id) else { return }
        deletingTaskIDs.insert(id)
        defer { deletingTaskIDs.remove(id) }

        await performCleanup(task: task)
        tasks.removeAll(where: { $0.id == id })
        worktreeURLByTaskID.removeValue(forKey: id)
        if selectedTaskID == id { selectedTaskID = nil }
        save()
    }

    /// surface teardown + wt remove を 1 まとめにした helper。deleteTask と
    /// moveToDone の両方から呼ばれる。呼び出し側は tasks 配列の更新や status
    /// 遷移を別途行うこと (この関数は物理 cleanup だけに責務を絞る)。
    ///
    /// wt remove 失敗は lastError に積むが throw しない — 上位が「タスクを
    /// 消す」操作自体を完遂できるように。worktree が手動削除済・未作成等の
    /// 場合でも先に進めるべきなので force を立てる。
    private func performCleanup(task: TaskCard) async {
        // transcript tail は surface teardown より先に止める (tail の delete
        // イベントが teardown と競合しないように)。
        stopTranscriptTail(taskID: task.id)

        if let surface = activeSurfaces[task.id] {
            await MainActor.run { surface.teardown() }
            activeSurfaces.removeValue(forKey: task.id)
            activitiesByTaskID.removeValue(forKey: task.id)
        }
        // activityLog は残さない (タスクが消える / done になるなら履歴も不要)。
        activityLog.removeValue(forKey: task.id)
        currentActivityByTaskID.removeValue(forKey: task.id)
        pendingPermissionByTaskID.removeValue(forKey: task.id)

        // タスクに紐づく shell タブも全て teardown する。cwd が worktree 内
        // にある可能性が高く、この後の `wt remove` で worktree dir 自体が
        // 消えるので、shell を残すと「cwd が存在しない dead shell」が
        // 宙に浮く (ls / cd すら効かなくなる)。
        if let shellIDs = shellTabOrderByTaskID.removeValue(forKey: task.id) {
            for sid in shellIDs {
                await MainActor.run { shellSurfaces[sid]?.teardown() }
                shellSurfaces.removeValue(forKey: sid)
                shellOwnerByID.removeValue(forKey: sid)
            }
        }
        selectedTerminalIDByTaskID.removeValue(forKey: task.id)
        collapseTerminalIfEmpty()

        if let wt = worktreeService {
            do {
                try await wt.remove(branch: task.branch, force: true)
            } catch {
                // 既に worktree が無い / branch が merged 済等で失敗しても、
                // タスク削除自体は進めたい。user に見える形で残しておくだけ。
                lastError = "wt remove failed: \(error) (worktree を手動削除してください)"
            }
        }

        // worktree path cache は成否に関わらず除去 — 存在しない dir で shell を
        // 開く事故を防ぐ。
        worktreeURLByTaskID.removeValue(forKey: task.id)
    }

    // MARK: - Repo selection

    /// NSOpenPanel で選ばれた URL を repoPath として採用する。
    /// WorktreeService の初期化に失敗した場合は lastError を立てる。
    func setRepoPath(_ path: String) {
        repoPath = path
        configureWorktreeService()
        save()
    }

    private func configureWorktreeService() {
        do {
            let url = URL(fileURLWithPath: repoPath)
            worktreeService = try WorktreeService(repoURL: url)
        } catch {
            worktreeService = nil
            lastError = "WorktreeService init failed: \(error)"
        }
    }

    // MARK: - Claude lifecycle

    /// Start ボタンから呼ばれる。wt create → TerminalSurface (libghostty 側で
    /// fork+execve) → inProgress へ同期遷移。プロセス exit は
    /// `handleSurfaceClosed` (close_surface_cb からの callback) で review に
    /// 飛ばす。
    func startTask(_ task: TaskCard) async {
        // 外側の薄いラッパー。Task を辞書に登録して cancelStart から
        // 取り出せるようにしてから本体 (`performStartTask`) を呼ぶ。
        // 同じタスクが既に start 中ならなにもしない (再押下防止)。
        guard startTaskTasks[task.id] == nil else { return }
        // `self?.performStartTask(...)` だと戻り値が Void? になって
        // Task<Void, Never> に代入できないため、先に unwrap してから呼ぶ。
        // self が既に deallocated の場合は Task の return 値は Void のままで
        // 型整合する (guard の early return)。
        let t: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performStartTask(task)
        }
        startTaskTasks[task.id] = t
        await t.value
        startTaskTasks.removeValue(forKey: task.id)
    }

    /// ユーザーが Starting 中のカードで × を押した時のエントリ。
    /// 登録 Task を cancel → WorktreeService.run の onCancel で SIGTERM が
    /// 飛ぶ → subprocess が止まり startTask の catch 節で CancellationError
    /// が拾われて静かに終了する。進捗バッジは performStartTask の defer が
    /// 自動で片付ける。
    func cancelStart(id: UUID) {
        startTaskTasks[id]?.cancel()
    }

    /// startTask の実体。Task cancel に対応するため wrapper と分離してある。
    private func performStartTask(_ task: TaskCard) async {
        guard let wt = worktreeService else {
            lastError = "リポジトリを選んでください (Choose Repo…)"
            return
        }
        guard task.status == .planning else { return }
        guard activeSurfaces[task.id] == nil else { return }

        // 進捗通知の起点。defer で必ずクリアする (成功 / 例外どちらでも)。
        startProgressByTaskID[task.id] = "準備中…"
        defer { startProgressByTaskID.removeValue(forKey: task.id) }

        do {
            // createOrAttach は「既存 worktree なら attach、未作成なら新規」を
            // 自動判別する。onProgress コールバックで wt stdout の line を
            // リアルタイムに startProgressByTaskID に流し、UI に表示する。
            let taskID = task.id
            let (worktreeURL, wasCreated) = try await wt.createOrAttach(
                branch: task.branch,
                onProgress: { [weak self] line in
                    Task { @MainActor in
                        self?.startProgressByTaskID[taskID] = line
                    }
                }
            )
            _ = wasCreated
            if let hookErr = await wt.lastHookError {
                lastError = hookErr
            }
            // hook 進行中に cancel された場合、createOrAttach は
            // CancellationError を throw するのでここには来ない。
            // 万一 isCancelled が true でここに辿り着いた場合 (例: hook が
            // 瞬時に完了して cancel が間に合わなかった) は、claude 起動を
            // スキップして planning のまま戻る。
            try Task.checkCancellation()

            startProgressByTaskID[task.id] = "claude を起動中…"
            let surface = try ClaudeSessionFactory.makeSurface(
                task: task,
                worktreeURL: worktreeURL,
                autoMode: autoModeEnabled
            )
            activeSurfaces[task.id] = surface
            worktreeURLByTaskID[task.id] = worktreeURL
            applyStatus(id: task.id, to: .inProgress)
        } catch is CancellationError {
            // ユーザーキャンセルは「通常経路」扱い。lastError に出さず、
            // 進捗バッジだけ消して planning のまま放置する
            // (worktree が部分的に作られた / 消されたかは wt の挙動次第。
            // ユーザーは再度 Start を押せば再開できる)。
            return
        } catch {
            lastError = "Start failed: \(error)"
        }
    }

    /// 手動で claude を止める。libghostty に gracefully close を依頼すると、
    /// 子プロセス (claude) に SIGHUP が届き、その後 close_surface_cb が発火。
    /// handleSurfaceClosed で review に遷移する。
    func stopTask(id: UUID) {
        activeSurfaces[id]?.requestClose()
    }

    /// surface が不在なタスクの詳細を開いた時、`claude --continue` で会話を
    /// 自動復帰させる。
    ///
    /// 対象ステージ:
    ///   - `review`: hook 経由でターン終了が通知された正常な終了
    ///   - `inProgress`: hook が飛ばずに surface だけ消えた状態 (app 強制終了、
    ///     claude プロセスクラッシュ、ssh 切断等)。ここを resume しないと
    ///     ユーザーは placeholder を見続けることになる
    ///
    /// planning / done は対象外 (planning は Start 前、done は worktree 削除済)。
    ///
    /// 呼び出し側: TaskDetailView が selectedTaskID 変化を検知して発火。
    /// 競合防止のため、activeSurfaces に既に entry があれば何もしない。
    /// worktree URL が手元に無い場合は `wt list` で引き直す
    /// (worktreeURLByTaskID は ephemeral なのでアプリ再起動後は空)。
    func resumeTask(_ task: TaskCard) async {
        // QA も review と同じ「セッションが寝ている」状態なので resume 対象。
        guard task.status.isReviewLike || task.status == .inProgress else { return }
        guard activeSurfaces[task.id] == nil else { return }
        // 既に resume 処理中なら重複起動しない (auto-resume と
        // TaskDetailView の onChange 経路が衝突した時の防壁)。
        guard !resumingTaskIDs.contains(task.id) else { return }
        guard let wt = worktreeService else {
            // repo 未設定ならそもそも resume できない。無音で抜ける
            // (ボード表示は placeholder のままになる)。
            return
        }

        resumingTaskIDs.insert(task.id)
        defer { resumingTaskIDs.remove(task.id) }

        // worktree URL を解決: cache にあれば採用 (ただし実在チェック必須
        // ——永続化されたパスはユーザーが手動削除しているとstaleになるので、
        // stale なら wt.list() に fallback する)。
        let fm = FileManager.default
        let worktreeURL: URL
        if let cached = worktreeURLByTaskID[task.id],
           fm.fileExists(atPath: cached.path) {
            worktreeURL = cached
        } else {
            do {
                let all = try await wt.list()
                guard let found = all.first(where: { $0.branch == task.branch }) else {
                    // worktree が無い = 前回手動削除されたか wt が壊れた可能性。
                    // cache も stale なので除去。
                    worktreeURLByTaskID.removeValue(forKey: task.id)
                    save()
                    return
                }
                worktreeURL = URL(fileURLWithPath: found.path)
                worktreeURLByTaskID[task.id] = worktreeURL
                save()
            } catch {
                lastError = "wt list failed while resuming: \(error)"
                return
            }
        }

        do {
            let surface = try ClaudeSessionFactory.makeSurface(
                task: task,
                worktreeURL: worktreeURL,
                resume: true,
                autoMode: autoModeEnabled
            )
            activeSurfaces[task.id] = surface

            // 復帰直後の claude は「前回のやり取りを表示して入力待ち」=
            // 意味論的に review (needsInput)。異常終了で inProgress に
            // 固まっていたタスクをここで正規化することで、次に prompt を
            // 打った瞬間に review → inProgress → stop → review の通常
            // サイクルに戻れる。
            if task.status == .inProgress {
                applyStatus(id: task.id, to: .review)
            }
            activitiesByTaskID[task.id] = .needsInput
        } catch {
            lastError = "Resume failed: \(error)"
        }
    }

    // MARK: - Auto resume (launch)

    /// 起動時に inProgress / review / qa ステージかつ surface 不在のタスクを
    /// 集めて、`resumeTask` を並列実行する。
    ///
    /// **並列化の意図:** `claude --continue` は初期化に 2〜5 秒かかるので
    /// タスクが N 個あると直列では N × (2〜5)s。`withTaskGroup` で並列化
    /// すると各 resume は独立 subprocess なので合計時間が
    /// `max(per-task time)` に圧縮される。worktreeURLByTaskID が永続化
    /// 済みのため `wt list` subprocess も不要で、さらに数百 ms を節約。
    ///
    /// **guard:** worktreeService が nil (= repo 未設定) なら無音で抜ける。
    /// resumeTask 自体も同じ guard を持つので冗長だが、無駄な TaskGroup
    /// 起動を避けるために先に判定する。
    private func restoreActiveSessionsAtLaunch() async {
        guard worktreeService != nil else { return }
        let candidates = tasks.filter { task in
            let isLiveStage = task.status == .inProgress
                || task.status.isReviewLike
            return isLiveStage && activeSurfaces[task.id] == nil
                && !resumingTaskIDs.contains(task.id)
        }
        guard !candidates.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for task in candidates {
                group.addTask { [weak self] in
                    // `of: Void.self` な TaskGroup は child task に Void を
                    // 要求するため、self?.resumeTask(...) の戻り値 Void?
                    // では型不一致。unwrap してから呼ぶ。
                    guard let self else { return }
                    await self.resumeTask(task)
                }
            }
        }
    }

    // MARK: - Shell tabs (expanded 中 ⌘T で開く普通のターミナル)

    /// 新しい shell タブを開き、shellSurfaces に追加する。
    /// 起動 shell はユーザーの `$SHELL` (fallback `/bin/zsh`)。
    ///
    /// **所有権:** 作成時の `selectedTaskID` が所有タスクになる。選択中 task
    /// が無い状態で呼ばれると shell に属する先が決められないので no-op
    /// (⌘T のキーボード shortcut は TaskDetailView がモーダル内部でのみ
    /// expose しているので、実際には常に task 選択中)。
    ///
    /// cwd の決定順:
    ///   1. 選択中タスクの worktree (Start 済で `worktreeURLByTaskID` にある)
    ///      — その claude と同じ workspace で脇作業 (`git log`, `rg` 等) が
    ///      できる方が実利用に合う。
    ///   2. main repo root — 選択中タスク無し or worktree 未作成時
    ///   3. nil — repoPath 未設定時 (shell は HOME で起動)
    ///
    /// `selectAsLeftPane`: true なら作成直後に selectedTerminalIDByTaskID を
    /// 更新して左ペインの active にする (⌘T の通常挙動)。split モードで
    /// 右ペイン専用に作る場合は false を渡す — 左ペインと同じ surface を
    /// 指すと libghostty の attach が競合して右が空になる。
    @discardableResult
    func openShellTab(selectAsLeftPane: Bool = true) -> UUID? {
        guard let ownerTID = selectedTaskID else { return nil }
        let id = UUID()
        let cwd: String? = preferredShellCwd()
        let surface = ShellTabFactory.makeSurface(
            id: id,
            workingDirectory: cwd
        )
        shellSurfaces[id] = surface
        shellOwnerByID[id] = ownerTID
        shellTabOrderByTaskID[ownerTID, default: []].append(id)
        if selectAsLeftPane {
            selectedTerminalIDByTaskID[ownerTID] = id
        }
        return id
    }

    /// openShellTab の cwd を解決する。選択中タスクの worktree を優先。
    private func preferredShellCwd() -> String? {
        if let taskID = selectedTaskID,
           let url = worktreeURLByTaskID[taskID] {
            return url.path
        }
        return repoPath.isEmpty ? nil : repoPath
    }

    // MARK: - Project shell tabs (task と無関係な「プロジェクト大元のシェル」)

    /// Project Shell Window で新しい shell タブを開く。cwd はプロジェクトの
    /// main repo root (`repoPath`)。空なら HOME。
    ///
    /// 戻り値 = 新規 shell の UUID (選択状態にもする)。
    @discardableResult
    func openProjectShellTab() -> UUID {
        let id = UUID()
        let cwd: String? = repoPath.isEmpty ? nil : repoPath
        let surface = ShellTabFactory.makeSurface(
            id: id,
            workingDirectory: cwd
        )
        projectShellSurfaces[id] = surface
        projectShellTabOrder.append(id)
        selectedProjectShellID = id
        return id
    }

    /// タブの × ボタンから呼ばれる。libghostty に close を依頼し、
    /// close_surface_cb 経由で `handleProjectShellClosed` が最終的な cleanup
    /// を行う (task 側の shell と同じパターン)。
    func requestCloseProjectShellTab(id: UUID) {
        projectShellSurfaces[id]?.requestClose()
    }

    /// `GhosttyNSView.onCloseRequested` 経由で呼ばれる。タブ配列から除去、
    /// 選択中タブなら別タブに飛ばす。
    func handleProjectShellClosed(id: UUID) {
        guard projectShellSurfaces[id] != nil else { return }
        projectShellSurfaces[id]?.teardown()
        projectShellSurfaces.removeValue(forKey: id)
        let removedIdx = projectShellTabOrder.firstIndex(of: id)
        projectShellTabOrder.removeAll { $0 == id }
        if selectedProjectShellID == id {
            if let idx = removedIdx, idx > 0, idx - 1 < projectShellTabOrder.count {
                selectedProjectShellID = projectShellTabOrder[idx - 1]
            } else {
                selectedProjectShellID = projectShellTabOrder.last
            }
        }
    }

    /// Project Shell Window が表示される時に「最低 1 タブは用意する」ための
    /// 自動初期化。onAppear から呼ばれる想定。既にタブがあれば何もしない。
    func ensureProjectShellReady() {
        if projectShellTabOrder.isEmpty {
            openProjectShellTab()
        }
    }

    /// ユーザーが shell タブを閉じた時。libghostty に SIGHUP を送ってもらい、
    /// close_surface_cb → handleShellTabClosed で actual cleanup。
    func requestCloseShellTab(id: UUID) {
        shellSurfaces[id]?.requestClose()
    }

    /// `GhosttyNSView.onCloseRequested` 経由で呼ばれる (shell タブ側)。
    /// タブ配列から除去、所有タスクで選択中だった場合は別タブ or claude
    /// (entry 削除) に戻す。
    func handleShellTabClosed(id: UUID) {
        guard shellSurfaces[id] != nil else { return }
        shellSurfaces[id]?.teardown()
        shellSurfaces.removeValue(forKey: id)

        guard let ownerTID = shellOwnerByID.removeValue(forKey: id) else {
            // 所有不明の孤児 shell (通常起きないが防衛的に)。surface を
            // 片付けたら戻る。
            collapseTerminalIfEmpty()
            return
        }

        var order = shellTabOrderByTaskID[ownerTID] ?? []
        let removedIdx = order.firstIndex(of: id)
        order.removeAll { $0 == id }
        if order.isEmpty {
            shellTabOrderByTaskID.removeValue(forKey: ownerTID)
        } else {
            shellTabOrderByTaskID[ownerTID] = order
        }

        if selectedTerminalIDByTaskID[ownerTID] == id {
            // 可能なら直前のタブ、無ければ末尾、無ければ claude (= entry 削除)
            if let idx = removedIdx, idx > 0, idx - 1 < order.count {
                selectedTerminalIDByTaskID[ownerTID] = order[idx - 1]
            } else if let last = order.last {
                selectedTerminalIDByTaskID[ownerTID] = last
            } else {
                selectedTerminalIDByTaskID.removeValue(forKey: ownerTID)
            }
        }
        collapseTerminalIfEmpty()
    }

    /// `GhosttyNSView.onCloseRequested` 経由で呼ばれる。libghostty が子プロセス
    /// 終了を検知したタイミングで review に飛ばす。
    func handleSurfaceClosed(taskID: UUID) {
        guard activeSurfaces[taskID] != nil else { return }
        activeSurfaces.removeValue(forKey: taskID)
        activitiesByTaskID.removeValue(forKey: taskID)
        pendingPermissionByTaskID.removeValue(forKey: taskID)
        // transcript tail も止める。session-end hook と冗長だが、hook が飛ばない
        // 異常終了経路 (SIGKILL 等) での fd leak を防ぐ安全弁。
        stopTranscriptTail(taskID: taskID)
        applyStatus(id: taskID, to: .review)
        collapseTerminalIfEmpty()
    }

    /// expanded モードを維持する surface が 1 つも無くなったら自動で解除する。
    /// 「surface ゼロ」= terminalArea が空 = expanded には意味がない状態。
    private func collapseTerminalIfEmpty() {
        if activeSurfaces.isEmpty && shellSurfaces.isEmpty {
            isTerminalExpanded = false
            selectedTerminalIDByTaskID.removeAll()
        }
    }

    // MARK: - Hook receiver

    /// Claude shim → CLI → socket → ここ (MainActor) の経路で event を受ける。
    ///
    /// Kanban のカラム意味論:
    ///   - inProgress = claude が能動的に作業中 (tool 実行 / reasoning)
    ///   - review     = claude のターンが終わってユーザー入力待ち (cmux の "needsInput")
    ///                  または claude プロセスが exit して再開不可
    ///   - done       = ユーザーが完了とした (手動 drag、cleanup 発火)
    ///
    /// したがって claude が動くたびにカードが inProgress ↔ review を行き来する。
    /// state machine (canTransition) は両方向を既に許可しているので、ここでは
    /// hook event を素直にカラム遷移へマッピングする。
    func handleHook(_ message: HookMessage) {
        guard let id = UUID(uuidString: message.surfaceID) else { return }
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        let current = tasks[idx].status

        switch message.event {
        case "session-start":
            // startTask が既に planning → inProgress に飛ばしているはず。
            // 念のため planning に居る場合だけ前進させる (kanbario 外で同じ
            // shim 設定を踏んだ場合の保護)。
            if current == .planning {
                applyStatusFromHook(idx: idx, to: .inProgress)
            }
            activitiesByTaskID[id] = .running
            // transcript JSONL の tail を開始して live log を流し込む。
            // Claude Code は SessionStart の stdin JSON に
            // `transcript_path` を含めるのでこれを最優先 (encode 規則に
            // 依存せず済む)。それが無い旧版互換のため、session_id +
            // worktreeURL からパスを自力構築する fallback も持つ。
            if let transcriptURL = Self.resolveTranscriptURL(
                payload: message.payload,
                worktreeURL: worktreeURLByTaskID[id]
            ) {
                startTranscriptTail(taskID: id, transcriptURL: transcriptURL)
            }

        case "prompt-submit", "pre-tool-use":
            // ユーザー入力 or tool 実行 = claude が能動的に動いている。
            // review / qa (= ユーザー待ち) からの「再開」を含めて inProgress へ。
            // qa は「review と同扱い」なので hook でも同列に扱う (ユーザーが
            // QA カラムで整理中に ⏎ を押した時も自然に inProgress へ戻す)。
            if current.isReviewLike || current == .planning {
                applyStatusFromHook(idx: idx, to: .inProgress)
            }
            activitiesByTaskID[id] = .running
            // 前ターンで来ていた permission 要求は「次のアクションが
            // 起きた時点」で解消したとみなしてクリア。
            pendingPermissionByTaskID.removeValue(forKey: id)

        case "stop":
            // ターン終了 = claude が「次のユーザー入力を待っています」状態。
            // Kanban 上で見える状態遷移として review カラムへ移す。
            // done に到達済 (ユーザーが先に完了とした) なら触らない。
            if current == .inProgress {
                applyStatusFromHook(idx: idx, to: .review)
            }
            activitiesByTaskID[id] = .needsInput

        case "session-end":
            // claude プロセス exit。close_surface_cb 経路と冗長 (どちらか
            // 早い方で review に飛ばせば良い)。activity は exit を意味する
            // 専用値が無いので消してしまう (= UI からは review 静止状態)。
            if current == .inProgress {
                applyStatusFromHook(idx: idx, to: .review)
            }
            activitiesByTaskID.removeValue(forKey: id)
            pendingPermissionByTaskID.removeValue(forKey: id)
            // transcript tail を停止 (fd leak 防止)。
            stopTranscriptTail(taskID: id)

        case "notification":
            // claude の Notification hook は tool 承認待ち / idle タイムアウト等で
            // 発火する。ユーザーが kanbario を裏に回していると気付けないので、
            // macOS Notification Center に昇格する + permission 系メッセージは
            // カード UI に専用バッジでも出す (気付きやすさ優先)。
            let body = Self.extractNotificationMessage(from: message.payload)
                ?? "Claude から通知があります"
            NotificationService.shared.post(
                title: tasks[idx].title,
                body: body,
                taskID: id
            )
            if Self.isPermissionMessage(body) {
                pendingPermissionByTaskID[id] = body
            }

        default:
            break
        }
    }

    /// hook 経由の status 書き換えは canTransition チェックを通さない
    /// (hook は authoritative)。idx は呼び出し側で resolve 済み前提。
    private func applyStatusFromHook(idx: Int, to status: TaskStatus) {
        tasks[idx].status = status
        tasks[idx].updatedAt = Date()
        save()
    }

    private func startHookReceiver() {
        let socketPath = Self.defaultHookSocketPath()
        let receiver = HookReceiver(socketPath: socketPath) { [weak self] message in
            Task { @MainActor in
                self?.handleHook(message)
            }
        }
        do {
            try receiver.start()
            hookReceiver = receiver
        } catch {
            lastError = "HookReceiver start failed: \(error)"
        }
    }

    /// CLI と app の両方が参照する socket path。Application Support 配下。
    static func defaultHookSocketPath() -> String {
        defaultSaveURL()
            .deletingLastPathComponent()
            .appendingPathComponent("hook.sock")
            .path
    }

    /// review / qa → done drag で呼ばれる。物理 cleanup (surface teardown +
    /// wt remove) → done 状態に遷移。cleanup が失敗しても done 状態までは
    /// 進める (worktree は手動削除できる前提)。
    func moveToDone(task: TaskCard) async {
        guard task.status.isReviewLike else { return }
        await performCleanup(task: task)
        applyStatus(id: task.id, to: .done)
    }

    /// 状態変更を tasks に反映し、永続化する低レベル関数。MainActor 前提。
    /// canTransition チェックを通さないので、呼び出し側が責任を持つこと。
    private func applyStatus(id: UUID, to status: TaskStatus) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].status = status
        tasks[idx].updatedAt = Date()
        save()
    }

    // MARK: - Persistence

    /// state.json のオンディスク形式。v1 は bare [TaskCard] だったので load で
    /// 両フォーマットをサポートする (書き出しは常にこの型)。
    ///
    /// **v3 (worktreeURLByTaskID 追加):** 自動セッション復元のため、taskID →
    /// worktree の絶対パスを永続化する。これにより再起動直後でも `wt list` を
    /// 叩かずに即 resume できる。
    ///
    /// **後方互換の要点 (2026-04-22 再発防止メモ):** Swift の synthesized
    /// `init(from:)` は struct field に `= [:]` の default を付けても**使わない**
    /// (decode 時は必ず `try container.decode` を呼ぶ)。結果として v2 の
    /// state.json (worktreeURLByTaskID キー無し) を decode しようとして
    /// `DecodingError.keyNotFound` が throw され、load が nil を返し、
    /// さらに save() で空 tasks が書き戻されてデータが消失する事故が発生した。
    /// 以降、新フィールドは **必ず手書きの `init(from:)` + `decodeIfPresent`**
    /// で受けること。
    struct PersistedState: Codable {
        var tasks: [TaskCard]
        var repoPath: String
        var worktreeURLByTaskID: [String: String]

        init(
            tasks: [TaskCard],
            repoPath: String,
            worktreeURLByTaskID: [String: String] = [:]
        ) {
            self.tasks = tasks
            self.repoPath = repoPath
            self.worktreeURLByTaskID = worktreeURLByTaskID
        }

        private enum CodingKeys: String, CodingKey {
            case tasks, repoPath, worktreeURLByTaskID
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.tasks = try c.decode([TaskCard].self, forKey: .tasks)
            self.repoPath = try c.decode(String.self, forKey: .repoPath)
            // v2 以前の state.json を読む場合、このキーは存在しない。
            // decodeIfPresent で optional 化して default [:] にフォールバック。
            self.worktreeURLByTaskID =
                (try c.decodeIfPresent([String: String].self,
                                       forKey: .worktreeURLByTaskID)) ?? [:]
        }
    }

    static func defaultSaveURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("kanbario")
        try? FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true
        )
        return appSupport.appendingPathComponent("state.json")
    }

    private func save() {
        // 書き込み前に既存 state.json を state.json.bak にコピー。
        // 今回のような migration ミスで空データ上書き事故が起きた際、
        // 直前の状態を復旧できる最後の安全弁になる。copyItem は既存 bak
        // があると失敗するので removeItem 先行。どちらのエラーも silent
        // (backup 失敗で save 自体を止めない)。
        let backupURL = saveURL.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.copyItem(at: saveURL, to: backupURL)

        // worktreeURLByTaskID は UUID キーを uuidString に変換して保存。
        // 辞書自体は transient な live 情報扱いだが、起動時の auto-resume で
        // wt list を避けるための cache として永続化する。
        var worktreeDict: [String: String] = [:]
        for (id, url) in worktreeURLByTaskID {
            worktreeDict[id.uuidString] = url.path
        }
        let snapshot = PersistedState(
            tasks: tasks,
            repoPath: repoPath,
            worktreeURLByTaskID: worktreeDict
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: saveURL, options: .atomic)
        } catch {
            print("[AppState] save failed: \(error)")
        }
    }

    private static func load(from url: URL) -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // v2/v3 (dict with tasks + repoPath [+ worktreeURLByTaskID]) を先に試し、
        // 失敗したら v1 (bare array) に落とす。
        if let v: PersistedState = try? decoder.decode(PersistedState.self, from: data) {
            return v
        }
        if let v1 = try? decoder.decode([TaskCard].self, from: data) {
            return PersistedState(tasks: v1, repoPath: "")
        }
        // どちらの decode も失敗 = 破損 or 未知 schema。生の JSON を捨てず
        // `state.json.corrupt-<unix>` として退避する。次回 save で空データが
        // 書き戻されても、この退避ファイルから生情報を復旧できる。
        let ts = Int(Date().timeIntervalSince1970)
        let rescueURL = url.appendingPathExtension("corrupt-\(ts)")
        try? FileManager.default.copyItem(at: url, to: rescueURL)
        print("[AppState] load failed; quarantined raw state to \(rescueURL.path)")
        return nil
    }

    // MARK: - Notification payload

    /// Notification hook の stdin JSON から `message` フィールドだけ抜く。
    /// Claude Code は `{ "hook_event_name": "Notification", "message": "..." }`
    /// 形式で渡してくる (他フィールドは無視してよい)。
    fileprivate static func extractNotificationMessage(from payload: String) -> String? {
        guard let data = payload.data(using: .utf8) else { return nil }
        struct NotificationPayload: Decodable { let message: String? }
        let decoded = try? JSONDecoder().decode(NotificationPayload.self, from: data)
        return decoded?.message?.isEmpty == false ? decoded?.message : nil
    }

    /// Notification message が tool permission / approval 要求系かを粗く判定。
    /// Claude Code の実際の message 例:
    ///   - "Claude needs your permission to use Bash"
    ///   - "Claude needs your permission to use Edit"
    ///   - "Approval required for ..."
    /// 単純なキーワード match で十分 (他の notification 種別、例えば idle
    /// タイムアウト通知は弾かれて通常の OS 通知だけになる)。
    fileprivate static func isPermissionMessage(_ body: String) -> Bool {
        let lowered = body.lowercased()
        return lowered.contains("permission")
            || lowered.contains("approval")
            || lowered.contains("needs your")
    }

    /// SessionStart hook の stdin JSON から transcript ファイル URL を解決する。
    ///
    /// 優先順:
    /// 1. payload の `transcript_path` (Claude Code が絶対パスで渡す)
    /// 2. payload の `session_id` + worktreeURL から自力構築
    ///    (古い Claude Code 版や encode 規則差異への fallback)
    ///
    /// どちらの情報も得られなければ nil → tail しない。
    fileprivate static func resolveTranscriptURL(
        payload: String,
        worktreeURL: URL?
    ) -> URL? {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let path = json["transcript_path"] as? String, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let sessionID = (json["session_id"] as? String)
            ?? (json["sessionId"] as? String)
            ?? ""
        guard !sessionID.isEmpty, let worktreeURL else { return nil }
        return TranscriptTailer.transcriptURL(
            for: worktreeURL, sessionID: sessionID
        )
    }

    // MARK: - Transcript tail

    /// 新しい TranscriptTailer を起動し、activityLog と currentActivityByTaskID
    /// を更新する buffer として受ける。既に tailer が動いているタスクでは
    /// no-op (重複起動で log が二重化するのを防ぐ)。
    fileprivate func startTranscriptTail(
        taskID: UUID,
        transcriptURL: URL
    ) {
        guard transcriptTailers[taskID] == nil else { return }
        let tailer = TranscriptTailer(transcriptURL: transcriptURL) { [weak self] entry, rawLine in
            // closure boundary を越えるのは Sendable な Data まで。
            // dict 化は MainActor 内で行う (Any の Sendable 違反を回避)。
            Task { @MainActor in
                guard let self else { return }
                if let entry {
                    var log = self.activityLog[taskID] ?? []
                    log.append(entry)
                    // 保持件数上限 50 (UI 表示は末尾 3-5 件のみ、残りは将来
                    // スクロール展開できるよう残す。メモリ肥大の抑制)。
                    if log.count > 50 { log.removeFirst(log.count - 50) }
                    self.activityLog[taskID] = log
                }
                if let raw = (try? JSONSerialization.jsonObject(with: rawLine))
                    as? [String: Any] {
                    self.updateCurrentActivity(taskID: taskID, raw: raw)
                }
            }
        }
        transcriptTailers[taskID] = tailer
        tailer.start()
    }

    fileprivate func stopTranscriptTail(taskID: UUID) {
        transcriptTailers[taskID]?.stop()
        transcriptTailers.removeValue(forKey: taskID)
        currentActivityByTaskID.removeValue(forKey: taskID)
    }

    /// transcript 行 1 つから CurrentActivity を更新する。
    ///
    /// ルール:
    /// - `type == "user"` with plain text → turnStartedAt = 時刻、activeTool クリア
    /// - `type == "user"` with tool_result → 対応 activeToolID を解消 (クリア)
    /// - `type == "assistant"` with TodoWrite tool_use → todos 更新
    /// - `type == "assistant"` with 他 tool_use → activeTool を設定
    ///
    /// tool_result は Claude の transcript では user message として記録される
    /// (Claude SDK の慣例)。この点を踏まえて分岐する。
    private func updateCurrentActivity(taskID: UUID, raw: [String: Any]) {
        var activity = currentActivityByTaskID[taskID] ?? CurrentActivity()
        let type = (raw["type"] as? String) ?? ""
        let timestamp = (raw["timestamp"] as? String)
            .flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()

        switch type {
        case "user":
            if let message = raw["message"] as? [String: Any],
               let blocks = message["content"] as? [[String: Any]] {
                // tool_result を含む user message は「tool の完了通知」で
                // ある。該当 id がクリアされて「実行中」状態が終わる。
                for b in blocks {
                    if (b["type"] as? String) == "tool_result",
                       let toolUseID = b["tool_use_id"] as? String,
                       toolUseID == activity.activeToolID {
                        activity.activeToolName = nil
                        activity.activeToolID = nil
                        activity.activeToolInputSummary = nil
                        break
                    }
                }
                // プレーンテキストを含む user message は新しいターンの開始。
                let hasText = blocks.contains { ($0["type"] as? String) == "text" }
                if hasText || message["content"] is String {
                    activity.turnStartedAt = timestamp
                    activity.activeToolName = nil
                    activity.activeToolID = nil
                    activity.activeToolInputSummary = nil
                }
            } else if let s = (raw["message"] as? [String: Any])?["content"] as? String,
                      !s.isEmpty {
                activity.turnStartedAt = timestamp
            }
        case "assistant":
            if let message = raw["message"] as? [String: Any],
               let blocks = message["content"] as? [[String: Any]] {
                for b in blocks {
                    guard (b["type"] as? String) == "tool_use",
                          let name = b["name"] as? String,
                          let id = b["id"] as? String else { continue }
                    let input = b["input"] as? [String: Any] ?? [:]
                    if name == "TodoWrite",
                       let todos = input["todos"] as? [[String: Any]] {
                        activity.todos = todos.compactMap { dict in
                            guard let content = dict["content"] as? String,
                                  let status = dict["status"] as? String
                            else { return nil }
                            return TodoItem(
                                content: content,
                                status: status,
                                activeForm: dict["activeForm"] as? String
                            )
                        }
                    } else {
                        activity.activeToolName = name
                        activity.activeToolID = id
                        activity.activeToolInputSummary = Self.summarizeToolInput(input)
                    }
                }
            }
        default:
            break
        }

        currentActivityByTaskID[taskID] = activity
    }

    /// tool_use の input から 1 行サマリを作る (UI 表示用、40 文字くらい)。
    /// 代表的な key (file_path / url / command / pattern) を優先、無ければ
    /// 先頭 key を使う。
    private static func summarizeToolInput(_ input: [String: Any]) -> String? {
        if input.isEmpty { return nil }
        let preferredKeys = ["file_path", "path", "url", "command", "pattern",
                             "prompt", "description"]
        let key = preferredKeys.first(where: { input[$0] != nil })
            ?? input.keys.sorted().first
        guard let key else { return nil }
        let value = input[key]
        let stringValue: String
        if let s = value as? String {
            stringValue = s
        } else if let v = value {
            stringValue = "\(v)"
        } else {
            return nil
        }
        let single = stringValue.replacingOccurrences(of: "\n", with: " ")
        let truncated = single.count > 50
            ? String(single.prefix(50)) + "…"
            : single
        return "(\(truncated))"
    }
}

// MARK: - NotificationService

/// macOS Notification Center の薄いラッパ兼 click handler。
///
/// App Sandbox = NO なので UNUserNotificationCenter の追加 entitlement は不要。
/// 初回 `requestAuthorizationIfNeeded` で OS の permission dialog が出る
/// (拒否時は silent no-op)。権限が確定するまで post を呼ぶと OS 側で黙って
/// 捨てられるだけだが、無駄な OS 呼び出しを抑えるため authorized flag を持つ。
///
/// **click → モーダル展開:** `UNUserNotificationCenterDelegate` を実装し、
/// 通知をクリックした時に userInfo["task_id"] から task を復元して
/// `AppState.selectedTaskID` にセットする。これで通知を開いた瞬間に該当
/// タスクの詳細モーダルが前面に出る (モーダル表示は selectedTaskID 非 nil
/// で自動展開する ContentView の既存挙動を利用)。
///
/// delegate は `UNUserNotificationCenter.current().delegate` に set する。
/// AppState.init から `configure(appState:)` を呼ぶので、AppState 1 つに対し
/// delegate 1 つが固定される (Singleton NotificationService を前提)。
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private var authorized = false
    private var requested = false
    /// AppState への weak 参照。Singleton が AppState を retain してしまうと
    /// deinit が走らなくなるため weak。
    private weak var appState: AppState?

    private override init() { super.init() }

    /// AppState から 1 度だけ呼ばれる。delegate の set もここで行う。
    func configure(appState: AppState) {
        self.appState = appState
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorizationIfNeeded() {
        guard !requested else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    /// 通知を飛ばす。`taskID` を userInfo に載せておき、ユーザーが通知を
    /// click した時にどのタスクを前面化すべきかを復元できるようにする。
    func post(title: String, body: String, taskID: UUID? = nil) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let taskID {
            content.userInfo = ["task_id": taskID.uuidString]
        }
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// App が foreground の時でも banner / sound を出す。kanbario を見ながら
    /// 作業中にも permission 要求に気付ける方が実利用に合う (既定は
    /// foreground では通知を抑制するため、明示的に許可)。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// 通知をクリックした時。userInfo から task_id を取り出して
    /// `appState.selectedTaskID` にセット = 既存の TaskDetail モーダルが
    /// 前面展開する。さらに `NSApp.activate` でウィンドウ自体を前面化する
    /// (kanbario が背面にある状態で通知を開いたケースの UX)。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let idString = userInfo["task_id"] as? String
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard let self, let state = self.appState else { return }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            guard let idString, let id = UUID(uuidString: idString) else { return }
            // 該当タスクが既に削除されていたら何もしない (タスクリストに
            // 存在しない ID を selected にしてしまうと詳細が出ない空モーダルに
            // なる)。modal が既に他 task を表示中の場合も上書きで切り替える。
            guard state.tasks.contains(where: { $0.id == id }) else { return }
            state.selectedTaskID = id
        }
    }
}
