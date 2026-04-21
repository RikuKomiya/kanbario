import Foundation
import Observation
import UserNotifications

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

    /// expanded 中に ⌘T で開く「普通のシェル」タブ。claude と違ってタスクに
    /// 紐付かず、ユーザーが明示的に閉じるまで live。辞書 + 順序配列のペアで
    /// 管理しているのはタブ並び順を保持しつつ surface を O(1) 引けるようにする
    /// ため (SwiftDictionary は順序非保持)。
    var shellSurfaces: [UUID: TerminalSurface] = [:]
    var shellTabOrder: [UUID] = []

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

    /// taskID → 稼働中の TranscriptTailer。session-start で起動、
    /// session-end / performCleanup / handleSurfaceClosed で停止する。
    private var transcriptTailers: [UUID: TranscriptTailer] = [:]

    /// terminalArea で「今表示すべき surface」の ID。
    /// - nil: 選択中タスクの claude surface (従来挙動)
    /// - non-nil かつ shellSurfaces にある: その shell タブ
    ///
    /// タスク切替時は自動的に claude 側に戻す (選択中タスクが変わったのに
    /// 別 shell を見続けるのは混乱するため)。
    var selectedTerminalID: UUID?

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
        }
        // repoPath が生きていれば WorktreeService を立ち上げる。起動時に
        // wt バイナリが PATH から消えている可能性を握りつぶしたくないので
        // 失敗したら lastError に流して UI に見せる。
        if !repoPath.isEmpty {
            configureWorktreeService()
        }
        startHookReceiver()
        NotificationService.shared.requestAuthorizationIfNeeded()
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
    /// - nil / 空の場合は uuid ベースの `kanbario/<uuid6>` を fallback として使う。
    ///
    /// 以前は addTask 直後に fire-and-forget で LLM 呼び出しを走らせていたが、
    /// タスク作成後に branch 名が非同期に書き換わるのが UX 的に予測しにくく、
    /// 古い name で wt remove に失敗するレース条件もあったため廃止。branch 名
    /// の選択は NewTaskSheet に移譲し、ユーザーが明示的に決める形にした。
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
            return "kanbario/\(id.uuidString.prefix(6).lowercased())"
        }()
        let task = TaskCard(
            id: id,
            projectID: defaultProject.id,
            title: title,
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

    /// タスクのステータスを変更する。
    /// review → done は worktree cleanup + claude kill を伴うので非同期分岐。
    /// それ以外 (planning → inProgress 等) は従来どおり同期で書き換える。
    func moveTask(id: UUID, to newStatus: TaskStatus) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        let current = tasks[idx].status
        guard current.canTransition(to: newStatus) else { return }

        if current == .review && newStatus == .done {
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
    func deleteTask(id: UUID) async {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
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
            collapseTerminalIfEmpty()
        }
        // activityLog は残さない (タスクが消える / done になるなら履歴も不要)。
        activityLog.removeValue(forKey: task.id)
        currentActivityByTaskID.removeValue(forKey: task.id)
        pendingPermissionByTaskID.removeValue(forKey: task.id)

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
        guard let wt = worktreeService else {
            lastError = "リポジトリを選んでください (Choose Repo…)"
            return
        }
        guard task.status == .planning else { return }
        guard activeSurfaces[task.id] == nil else { return }

        do {
            // createOrAttach は「既存 worktree なら attach、未作成なら新規」を
            // 自動判別する。ユーザーが NewTaskSheet の branch picker で既存
            // branch を選んだケース / 既に途中まで作業していた branch を指定
            // したケースが両方シームレスに扱える。
            let (worktreeURL, wasCreated) = try await wt.createOrAttach(branch: task.branch)
            _ = wasCreated  // hook 実行は WorktreeService 内部で行う
            // post-create hook が失敗していれば warning を露出する
            // (worktree 自体は作成済なので起動は続行する。ユーザーが hook を
            //  設定していないケースでは nil のまま何も通知しない)。
            if let hookErr = await wt.lastHookError {
                lastError = hookErr
            }
            let surface = try ClaudeSessionFactory.makeSurface(
                task: task, worktreeURL: worktreeURL
            )
            activeSurfaces[task.id] = surface
            worktreeURLByTaskID[task.id] = worktreeURL
            applyStatus(id: task.id, to: .inProgress)
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
        guard task.status == .review || task.status == .inProgress else { return }
        guard activeSurfaces[task.id] == nil else { return }
        guard let wt = worktreeService else {
            // repo 未設定ならそもそも resume できない。無音で抜ける
            // (ボード表示は placeholder のままになる)。
            return
        }

        // worktree URL を解決: ephemeral dict にあればそれ、
        // 無ければ wt.list() で branch から逆引き。
        let worktreeURL: URL
        if let cached = worktreeURLByTaskID[task.id] {
            worktreeURL = cached
        } else {
            do {
                let all = try await wt.list()
                guard let found = all.first(where: { $0.branch == task.branch }) else {
                    // worktree が無い = 前回手動削除されたか wt が壊れた可能性。
                    // エラーにせず placeholder を残す (ユーザーが気付けるよう
                    // lastError に残してもいいが、毎回 modal 開くたびに alert
                    // が出ると煩いので silent に)。
                    return
                }
                worktreeURL = URL(fileURLWithPath: found.path)
                worktreeURLByTaskID[task.id] = worktreeURL
            } catch {
                lastError = "wt list failed while resuming: \(error)"
                return
            }
        }

        do {
            let surface = try ClaudeSessionFactory.makeSurface(
                task: task, worktreeURL: worktreeURL, resume: true
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

    // MARK: - Shell tabs (expanded 中 ⌘T で開く普通のターミナル)

    /// 新しい shell タブを開き、activeSurfaces に追加する。
    /// 起動 shell はユーザーの `$SHELL` (fallback `/bin/zsh`)。
    ///
    /// cwd の決定順:
    ///   1. 選択中タスクの worktree (Start 済で `worktreeURLByTaskID` にある)
    ///      — その claude と同じ workspace で脇作業 (`git log`, `rg` 等) が
    ///      できる方が実利用に合う。
    ///   2. main repo root — 選択中タスク無し or worktree 未作成時
    ///   3. nil — repoPath 未設定時 (shell は HOME で起動)
    ///
    /// `selectAsLeftPane`: true なら作成直後に `selectedTerminalID` を更新して
    /// 左ペインの active にする (⌘T の通常挙動)。split モードで右ペイン専用に
    /// 作る場合は false を渡す — 左ペインと同じ surface を指すと libghostty の
    /// attach が競合して右が空になる。
    @discardableResult
    func openShellTab(selectAsLeftPane: Bool = true) -> UUID? {
        let id = UUID()
        let cwd: String? = preferredShellCwd()
        let surface = ShellTabFactory.makeSurface(
            id: id,
            workingDirectory: cwd
        )
        shellSurfaces[id] = surface
        shellTabOrder.append(id)
        if selectAsLeftPane {
            selectedTerminalID = id
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

    /// ユーザーが shell タブを閉じた時。libghostty に SIGHUP を送ってもらい、
    /// close_surface_cb → handleShellTabClosed で actual cleanup。UI は即座に
    /// 「閉じた」フィードバックを返したいので selectedTerminalID は先に動かす。
    func requestCloseShellTab(id: UUID) {
        shellSurfaces[id]?.requestClose()
    }

    /// `GhosttyNSView.onCloseRequested` 経由で呼ばれる (shell タブ側)。
    /// タブ配列から除去、選択中なら別タブ or claude に戻す。
    func handleShellTabClosed(id: UUID) {
        guard shellSurfaces[id] != nil else { return }
        shellSurfaces[id]?.teardown()
        shellSurfaces.removeValue(forKey: id)
        let removedIdx = shellTabOrder.firstIndex(of: id)
        shellTabOrder.removeAll { $0 == id }
        if selectedTerminalID == id {
            // 可能なら直前のタブ、無ければ末尾、無ければ claude (= nil)
            if let idx = removedIdx, idx > 0, idx - 1 < shellTabOrder.count {
                selectedTerminalID = shellTabOrder[idx - 1]
            } else {
                selectedTerminalID = shellTabOrder.last
            }
        }
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
            selectedTerminalID = nil
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
            // review (= ユーザー待ち) からの「再開」を含めて inProgress へ。
            if current == .review || current == .planning {
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
            NotificationService.shared.post(title: tasks[idx].title, body: body)
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

    /// review → done drag で呼ばれる。物理 cleanup (surface teardown + wt remove)
    /// → done 状態に遷移。cleanup が失敗しても done 状態までは進める
    /// (worktree は手動削除できる前提)。
    func moveToDone(task: TaskCard) async {
        guard task.status == .review else { return }
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
    struct PersistedState: Codable {
        var tasks: [TaskCard]
        var repoPath: String
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
        let snapshot = PersistedState(tasks: tasks, repoPath: repoPath)
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
        // v2 (dict with tasks + repoPath) を先に試し、失敗したら v1 (bare array) に落とす。
        if let v2 = try? decoder.decode(PersistedState.self, from: data) {
            return v2
        }
        if let v1 = try? decoder.decode([TaskCard].self, from: data) {
            return PersistedState(tasks: v1, repoPath: "")
        }
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

/// macOS Notification Center の薄いラッパ。
///
/// App Sandbox = NO なので UNUserNotificationCenter の追加 entitlement は不要。
/// 初回 post で OS の permission dialog が出る (拒否時は silent no-op)。
/// 権限が確定するまで post を呼ぶと OS 側で黙って捨てられるだけなので、
/// authorized フラグによる早期 return は必須ではないが、無駄な OS 呼び出しを
/// 抑えるために保持している。
@MainActor
fileprivate final class NotificationService {
    static let shared = NotificationService()

    private var authorized = false
    private var requested = false

    private init() {}

    func requestAuthorizationIfNeeded() {
        guard !requested else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    func post(title: String, body: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
