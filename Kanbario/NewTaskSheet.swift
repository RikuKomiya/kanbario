import SwiftUI

/// 新規タスクの planning カードを作るシート。wireframe の MVPCard (planning 段階)
/// を後で正しく描画できるよう、tag / risk / owner / prompt version / needs を
/// 任意入力できる。どれも省略可能 — 最低限は title + body があれば作れる。
struct NewTaskSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var branchInput: String = ""
    @State private var tag: LLMTag? = nil
    @State private var risk: RiskLevel? = nil
    @State private var owner: String = ""
    @State private var promptV: String = ""
    @State private var needsInput: String = ""   // カンマ区切り

    /// ✨ AI ボタンで LLM branch 生成中の spinner フラグ。
    @State private var isGeneratingBranch: Bool = false
    /// 生成失敗時のフォーム内インライン表示 (alert 連打を避ける)。
    @State private var branchGenerationError: String? = nil
    /// 既存 branch picker 用のキャッシュ。sheet open 時に 1 回ロード。
    @State private var availableBranches: [String] = []
    /// `@` autocomplete で使う repo ファイル一覧 (git ls-files)。sheet open 時に 1 回ロード。
    @State private var availableFiles: [FileEntry] = []
    /// `/` autocomplete で使う skills / commands 一覧 (~/.claude + project/.claude)。
    @State private var availableSlashes: [SlashEntry] = []

    @FocusState private var focus: Field?
    enum Field { case title, body, branch, owner, promptV, needs }

    var body: some View {
        // 画面が小さいとフィールド全部入り切らないので ScrollView で縦スクロール可。
        // actionRow は常に末尾に固定したほうが UX が素直だが、MVP としては
        // 一体スクロールで問題なし (sheet が小さい時だけユーザーが下まで
        // スクロールして Save / Cancel にアクセスする動作になる)。
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                titleField
                bodyField

                HStack(alignment: .top, spacing: 16) {
                    tagPicker
                    riskPicker
                }

                HStack(alignment: .top, spacing: 16) {
                    ownerField
                    promptVField
                }

                branchField

                needsField

                actionRow
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620, minHeight: 560)
        .background(WF.paper)
        .foregroundStyle(WF.ink)  // 子孫の system TextField 等がダークモード時に白文字になるのを防止
        .tint(WF.ink)              // カーソル / selection も ink 色へ揃える
        .preferredColorScheme(.light)  // 紙色テーマは light 前提
        .onAppear { focus = .title }
        .task {
            // 既存 branch picker 用に repo の local branch 一覧を 1 回ロード。
            // Sheet 表示中に branch が増えることは稀なので再ロード不要。
            if let wt = appState.worktreeService {
                availableBranches = await wt.allBranches()
            }
            // prompt editor の @ / autocomplete 用データも並行取得。
            // repoPath 必須 (FileListService / SkillDiscovery 両方が repo 起点)。
            if !appState.repoPath.isEmpty {
                async let files = FileListService.shared.files(in: appState.repoPath)
                async let slashes = SkillDiscovery.shared.entries(for: appState.repoPath)
                availableFiles = await files
                availableSlashes = await slashes
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Hand("New planning task", size: 24, weight: .bold)
            Squiggle(width: 110)
        }
    }

    // MARK: - Title / body

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Hand("Title (optional)", size: 12, color: WF.ink2)
            TextField("空欄 OK · prompt の先頭 10 文字を自動採用", text: $title)
                .textFieldStyle(.plain)
                .font(WFFont.hand(15, weight: .bold))
                .foregroundStyle(WF.ink)
                .padding(8)
                .background(WF.paperAlt, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(focus == .title ? WF.accent : WF.line, lineWidth: 1.3)
                )
                .focused($focus, equals: .title)
        }
    }

    private var bodyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Hand("Claude prompt", size: 12, color: WF.ink2)
                Spacer()
                Text("@ で file · / で command/skill")
                    .font(WFFont.mono(10))
                    .foregroundStyle(WF.ink3)
            }
            // **clipShape を付けない:** autocomplete popup は editor の下に
            // はみ出す必要があるので、background / overlay に shape を埋め込む
            // (外形の角丸見た目は維持) が、子ツリー全体をクリップしないように
            // する。popup は editor 枠外で描画されつつ、AppKit の NSTextView
            // 内部テキストは自前 bounds 管理なので見た目崩れは起きない。
            PromptEditorWithAutocomplete(
                text: $bodyText,
                files: availableFiles,
                slashes: availableSlashes
            )
            .padding(4)
            .background(WF.paperAlt, in: RoundedRectangle(cornerRadius: 8))
            .frame(minHeight: 120)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(WF.line, lineWidth: 1.3)
            )
        }
    }

    // MARK: - Tag / risk pickers

    private var tagPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Hand("Tag", size: 12, color: WF.ink2)
            WrapLayout(spacing: 6, rowSpacing: 6) {
                ForEach(LLMTag.allCases, id: \.self) { t in
                    Button {
                        tag = (tag == t) ? nil : t
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(t.color).frame(width: 5, height: 5)
                            Text(t.rawValue).font(WFFont.hand(12))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .foregroundStyle(tag == t ? t.color : WF.ink2)
                        .background(
                            Capsule().fill(tag == t ? t.color.opacity(0.1) : Color.clear)
                        )
                        .overlay(Capsule().stroke(tag == t ? t.color : WF.ink3, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var riskPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Hand("Risk", size: 12, color: WF.ink2)
            HStack(spacing: 6) {
                ForEach(RiskLevel.allCases, id: \.self) { r in
                    Button {
                        risk = (risk == r) ? nil : r
                    } label: {
                        Text(r.label)
                            .font(WFFont.hand(12))
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .foregroundStyle(risk == r ? r.color : WF.ink2)
                            .background(
                                Capsule().fill(risk == r ? r.color.opacity(0.12) : Color.clear)
                            )
                            .overlay(Capsule().stroke(risk == r ? r.color : WF.ink3, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Owner / prompt version

    private var ownerField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Hand("Owner (1 char)", size: 12, color: WF.ink2)
            TextField("e.g. M", text: $owner)
                .textFieldStyle(.plain)
                .font(WFFont.hand(14, weight: .bold))
                .foregroundStyle(WF.ink)
                .padding(6)
                .background(WF.paperAlt, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(WF.line, lineWidth: 1.3))
                .focused($focus, equals: .owner)
                .onChange(of: owner) { _, newVal in
                    if newVal.count > 2 {
                        owner = String(newVal.prefix(2))
                    }
                }
        }
    }

    private var promptVField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Hand("Prompt version", size: 12, color: WF.ink2)
            TextField("e.g. v0.3", text: $promptV)
                .textFieldStyle(.plain)
                .font(WFFont.mono(12))
                .foregroundStyle(WF.ink)
                .padding(6)
                .background(WF.paperAlt, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(WF.line, lineWidth: 1.3))
                .focused($focus, equals: .promptV)
        }
    }

    // MARK: - Branch name + AI generator

    /// branch 名入力欄 + ✨ AI ボタン。空欄ならタスク作成時に
    /// `kanbario/<uuid6>` が自動付与される (placeholder でその旨を示す)。
    /// ✨ ボタンは title/body をプロンプトに Haiku 4.5 で slug を生成し、
    /// 返ってきた値を入力欄に差し込む。生成中は spinner + disable。
    private var branchField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Hand("Branch name", size: 12, color: WF.ink2)
                Spacer()
                existingBranchMenu
                aiGenerateButton
            }
            TextField("空欄で feature/<auto> · 例: feature/add-auth-tests",
                      text: $branchInput)
                .textFieldStyle(.plain)
                .font(WFFont.mono(12))
                .foregroundStyle(WF.ink)
                .padding(8)
                .background(WF.paperAlt, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(focus == .branch ? WF.accent : WF.line, lineWidth: 1.3)
                )
                .focused($focus, equals: .branch)
            if let err = branchGenerationError {
                Text(err)
                    .font(WFFont.mono(10))
                    .foregroundStyle(WF.pink)
                    .lineLimit(2)
            }
        }
    }

    /// 📋 既存 branch ドロップダウン。repo の local branch 全部から選んで
    /// input 欄に差し込む。選んだ branch に既存 worktree があれば Start 時に
    /// 自動で attach、無ければ新規 worktree 作成。
    @ViewBuilder
    private var existingBranchMenu: some View {
        Menu {
            if availableBranches.isEmpty {
                Button("(no branches)") { }
                    .disabled(true)
            } else {
                ForEach(availableBranches, id: \.self) { b in
                    Button {
                        branchInput = b
                    } label: {
                        Text(b)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 11))
                Text("Existing").font(WFFont.hand(11, weight: .bold))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(WF.ink2)
            .overlay(Capsule().stroke(WF.ink3.opacity(0.7), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("既存の branch から選択 (worktree が既にあれば attach、無ければ新規作成)")
    }

    /// ✨ Generate ボタン。title か body のいずれかが入っていれば叩ける。
    /// 生成中は disable。タップで `BranchNameGenerator.generate` を呼んで
    /// branchInput に反映。
    ///
    /// **title が空でも body だけで動く**: buildPrompt は title / body を
    /// 両方受けて「タスクの INTENT」として LLM に渡すので、片方だけでも
    /// 意味のある slug が出る。実運用では body (日本語の長文 prompt) しか
    /// 書かずに ✨ を押すケースが多いので、title 必須にしていると体験が
    /// 悪い。
    private var aiGenerateButton: some View {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedBody = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasNoContent = trimmedTitle.isEmpty && trimmedBody.isEmpty
        let disabled = isGeneratingBranch || hasNoContent

        return Button {
            Task { await generateBranchName() }
        } label: {
            HStack(spacing: 4) {
                if isGeneratingBranch {
                    ProgressView().controlSize(.mini).scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                }
                Text("AI").font(WFFont.hand(11, weight: .bold))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(WF.accent)
            .overlay(
                Capsule().stroke(WF.accent.opacity(0.55), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(hasNoContent
              ? "Title か Claude prompt のどちらかを入力してください"
              : "ローカルの claude CLI で branch 名を生成 (数秒〜十数秒)")
    }

    /// `claude -p` を subprocess で呼んで branch slug を取得し、input 欄に
    /// `kanbario/<slug>` 形式で差し込む。API key は不要 — ユーザーが既に
    /// claude CLI にログインしていれば動く。
    ///
    /// 失敗は全て GenerationError として throw されるので、メッセージを
    /// フォーム内の薄い赤字に出す。alert 連打は避ける。
    @MainActor
    private func generateBranchName() async {
        branchGenerationError = nil
        isGeneratingBranch = true
        defer { isGeneratingBranch = false }
        do {
            let slug = try await BranchNameGenerator.generate(
                title: title, body: bodyText
            )
            branchInput = "feature/\(slug)"
        } catch {
            branchGenerationError = "生成失敗: \(error)"
        }
    }

    // MARK: - Needs

    private var needsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Hand("Needs (comma separated)", size: 12, color: WF.ink2)
            TextField("golden set, guardrails", text: $needsInput)
                .textFieldStyle(.plain)
                .font(WFFont.hand(13))
                .foregroundStyle(WF.ink)
                .padding(6)
                .background(WF.paperAlt, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(WF.line, lineWidth: 1.3))
                .focused($focus, equals: .needs)
        }
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
                .buttonStyle(.plain)
                .foregroundStyle(WF.ink2)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(WF.line, lineWidth: 1.2))

            Button {
                withAnimation(.smooth(duration: 0.3)) {
                    appState.addTask(
                        title: title,
                        body: bodyText,
                        branch: branchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? nil
                            : branchInput.trimmingCharacters(in: .whitespacesAndNewlines),
                        tag: tag,
                        risk: risk,
                        owner: owner.trimmingCharacters(in: .whitespaces).isEmpty
                            ? nil
                            : String(owner.prefix(1)).uppercased(),
                        promptV: promptV.trimmingCharacters(in: .whitespaces).isEmpty ? nil : promptV,
                        needs: parsedNeeds
                    )
                }
                dismiss()
            } label: {
                Hand("Save", size: 13, color: WF.paper)
                    .padding(.horizontal, 18).padding(.vertical, 6)
                    .background(WF.ink, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid)
            .opacity(isValid ? 1 : 0.4)
        }
    }

    private var parsedNeeds: [String]? {
        let parts = needsInput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts
    }

    /// body が非空 + whitespace のみでないこと (title は空 OK で body から自動採用)。
    private var isValid: Bool {
        !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

#Preview {
    NewTaskSheet()
        .environment(AppState())
}
