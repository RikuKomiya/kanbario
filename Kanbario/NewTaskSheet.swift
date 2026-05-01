import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 新規 planning タスクを作るシート。
///
/// 入力体験は「長い仕様書を書く prompt」を主役にする。tag / risk / owner /
/// prompt version / needs は過去の wireframe メタとしてモデルには残すが、新規作成
/// UI からは外し、Markdown editor の高さと native 操作に面積を使う。
struct NewTaskSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var branchInput: String = ""
    @State private var selectedAgent: AgentKind = .claude

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
    /// 既に worktree がある branch。branch picker で attach / new を見分ける。
    @State private var attachedBranches: Set<String> = []
    /// Toolbar / drop / menu から prompt editor を native 操作するための handle。
    @State private var promptHandle = PromptEditorHandle()
    @State private var isBranchPickerPresented = false

    @FocusState private var focus: Field?
    enum Field { case title, branch }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            titleBranchRow
            promptField
            actionRow
        }
        .padding(24)
        .frame(minWidth: 780, idealWidth: 960, minHeight: 760, idealHeight: 880)
        .background(WF.paper)
        .foregroundStyle(WF.ink)
        .tint(WF.ink)
        .preferredColorScheme(.light)
        .task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            await MainActor.run {
                promptHandle.focus()
            }
        }
        .task {
            // 既存 branch picker 用に repo の local branch 一覧を 1 回ロード。
            if let wt = appState.worktreeService {
                availableBranches = await wt.allBranches()
                if let worktrees = try? await wt.list() {
                    attachedBranches = Set(worktrees.map(\.branch))
                }
            }
            // prompt editor の @ / autocomplete 用データも並行取得。
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
        HStack {
            Hand("New planning task", size: 24, weight: .bold)
            Spacer()
        }
        .overlay(alignment: .bottomLeading) {
            Squiggle(width: 110)
                .offset(y: 8)
        }
    }

    // MARK: - Title / branch

    private var titleBranchRow: some View {
        HStack(alignment: .top, spacing: 14) {
            titleField
                .frame(maxWidth: .infinity, alignment: .topLeading)
            agentField
                .frame(width: 170, alignment: .topLeading)
            branchField
                .frame(minWidth: 320, maxWidth: 390, alignment: .topLeading)
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("Title (optional)")
            TextField("空欄 OK · prompt の先頭 50 文字を自動採用", text: $title)
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

    private var agentField: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("Agent")
            Picker("", selection: $selectedAgent) {
                ForEach(AgentKind.allCases) { agent in
                    Text(agent.displayName).tag(agent)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("このタスクを起動する agent CLI")
        }
    }

    /// branch 名入力欄 + ✨ AI ボタン。空欄ならタスク作成時に
    /// `feature/<uuid6>` が自動付与される。
    private var branchField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                fieldLabel("Branch name")
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
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10, weight: .semibold))
                    Text(err)
                        .font(WFFont.mono(10))
                        .lineLimit(2)
                }
                .foregroundStyle(WF.warn)
            }
        }
    }

    /// 📋 既存 branch ドロップダウン。repo の local branch 全部から選んで
    /// input 欄に差し込む。選んだ branch に既存 worktree があれば Start 時に
    /// 自動で attach、無ければ新規 worktree 作成。
    @ViewBuilder
    private var existingBranchMenu: some View {
        Button {
            isBranchPickerPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 11))
                Text("Branches").font(WFFont.mono(11))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(WF.ink2)
            .background(WF.paper.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $isBranchPickerPresented, arrowEdge: .bottom) {
            BranchPickerPopover(
                branches: availableBranches,
                attachedBranches: attachedBranches,
                selection: $branchInput,
                onSelect: { isBranchPickerPresented = false }
            )
            .frame(width: 420, height: 360)
        }
        .help("既存の branch から選択 (worktree が既にあれば attach、無ければ新規作成)")
    }

    /// ✨ Generate ボタン。title か body のいずれかが入っていれば叩ける。
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
                Text("AI").font(WFFont.mono(11))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .font(WFFont.mono(11))
            .foregroundStyle(WF.ink2)
            .background(WF.paper.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(WF.line.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(hasNoContent
              ? "Title か Prompt spec のどちらかを入力してください"
              : "ローカルの claude CLI で branch 名を生成 (数秒〜十数秒)")
    }

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

    // MARK: - Prompt

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                fieldLabel("Prompt spec")
                Spacer()
                Text("⌘B/⌘I · Markdown toolbar · URL/file drop")
                    .font(WFFont.mono(10))
                    .foregroundStyle(WF.ink3)
            }
            MarkdownPromptComposer(
                text: $bodyText,
                files: availableFiles,
                slashes: availableSlashes,
                repoPath: appState.repoPath,
                handle: promptHandle
            )
            .frame(minHeight: 510, maxHeight: .infinity)
        }
        .layoutPriority(1)
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack {
            Text("\(bodyText.count) chars")
                .font(WFFont.mono(10))
                .foregroundStyle(WF.ink3)
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
                        agent: selectedAgent
                    )
                }
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Hand("Save", size: 13, color: WF.paper)
                    Text("⌘↵")
                        .font(WFFont.mono(9))
                        .foregroundStyle(WF.paper.opacity(0.72))
                }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(WF.ink, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!isValid)
            .opacity(isValid ? 1 : 0.4)
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(WFFont.mono(11))
            .foregroundStyle(WF.ink2)
    }

    /// body が非空 + whitespace のみでないこと (title は空 OK で body から自動採用)。
    private var isValid: Bool {
        !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct BranchPickerPopover: View {
    let branches: [String]
    let attachedBranches: Set<String>
    @Binding var selection: String
    var onSelect: () -> Void

    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WF.ink3)
                TextField("Search branch", text: $query)
                    .textFieldStyle(.plain)
                    .font(WFFont.mono(12))
                    .foregroundStyle(WF.ink)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(WF.paperAlt, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(WF.line.opacity(0.35), lineWidth: 1))

            HStack(spacing: 8) {
                BranchStatusPill(label: "attach", color: WF.ink2)
                BranchStatusPill(label: "new", color: WF.ink3)
                Spacer()
                Text("\(filteredBranches.count) branches")
                    .font(WFFont.mono(10))
                    .foregroundStyle(WF.ink3)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if filteredBranches.isEmpty {
                        Text(branches.isEmpty ? "No local branches found." : "No branch matches.")
                            .font(WFFont.mono(11))
                            .foregroundStyle(WF.ink3)
                            .frame(maxWidth: .infinity, minHeight: 90)
                    } else {
                        ForEach(filteredBranches, id: \.self) { branch in
                            Button {
                                selection = branch
                                onSelect()
                            } label: {
                                BranchPickerRow(
                                    branch: branch,
                                    isAttached: attachedBranches.contains(branch),
                                    isSelected: selection == branch
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(WF.paper)
    }

    private var filteredBranches: [String] {
        let sorted = branches.sorted { lhs, rhs in
            let lhsAttached = attachedBranches.contains(lhs)
            let rhsAttached = attachedBranches.contains(rhs)
            if lhsAttached != rhsAttached { return lhsAttached && !rhsAttached }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return sorted }
        return sorted.filter { $0.lowercased().contains(needle) }
    }
}

private struct BranchPickerRow: View {
    let branch: String
    let isAttached: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isAttached ? "point.3.connected.trianglepath.dotted" : "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(WF.ink3)
                .frame(width: 16)
            Text(branch)
                .font(WFFont.mono(12))
                .foregroundStyle(WF.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            BranchStatusPill(label: isAttached ? "attach" : "new", color: isAttached ? WF.ink2 : WF.ink3)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(isSelected ? WF.paperAlt : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct BranchStatusPill: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(WFFont.mono(9))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().stroke(color.opacity(0.55), lineWidth: 1))
    }
}

private struct MarkdownToolbarChip: View {
    let title: String
    var systemImage: String? = nil
    var isActive = false

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(title)
                .font(WFFont.mono(11))
        }
        .foregroundStyle(isActive ? WF.paper : (isHovering ? WF.ink : WF.ink2))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(fill, in: RoundedRectangle(cornerRadius: 7))
        .onHover { isHovering = $0 }
    }

    private var fill: Color {
        if isActive { return WF.ink }
        if isHovering { return WF.paper.opacity(0.7) }
        return .clear
    }
}

// MARK: - Markdown prompt composer

private struct MarkdownPromptComposer: View {
    @Binding var text: String
    let files: [FileEntry]
    let slashes: [SlashEntry]
    let repoPath: String
    let handle: PromptEditorHandle

    @State private var showPreview = false
    @State private var isDropTargeted = false
    @State private var areAttachmentsExpanded = false

    private let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp", "svg"
    ]
    private let starterTemplate = """
    # Goal
    - What should change?
    - Acceptance criteria
    - Edge cases
    """

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle()
                .fill(WF.line.opacity(0.16))
                .frame(height: 1)
            if showPreview {
                HSplitView {
                    editorPane
                        .frame(minWidth: 430)
                    previewPane
                        .frame(minWidth: 300, idealWidth: 380)
                }
            } else {
                editorPane
            }
        }
        .background(
            isDropTargeted ? WF.accentSoft.opacity(0.22) : WF.paperAlt,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(WF.line, lineWidth: isDropTargeted ? 2 : 1.3)
        )
        .shadow(color: WF.cardShadow, radius: 0, x: 2, y: 3)
        .onDrop(
            of: [.fileURL, .url, .plainText, .text],
            isTargeted: $isDropTargeted,
            perform: handleDrop(providers:)
        )
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    toolbarButton("H1", help: "Heading 1") {
                        handle.prefixSelectedLines(with: "# ", placeholder: "Heading")
                    }
                    toolbarButton("H2", help: "Heading 2") {
                        handle.prefixSelectedLines(with: "## ", placeholder: "Section")
                    }
                    toolbarButton("H3", help: "Heading 3") {
                        handle.prefixSelectedLines(with: "### ", placeholder: "Topic")
                    }
                    verticalDivider
                    toolbarButton("B", systemImage: "bold", help: "Bold (⌘B)") {
                        handle.wrapSelection(prefix: "**", suffix: "**", placeholder: "bold text")
                    }
                    .keyboardShortcut("b", modifiers: .command)
                    toolbarButton("I", systemImage: "italic", help: "Italic (⌘I)") {
                        handle.wrapSelection(prefix: "_", suffix: "_", placeholder: "italic text")
                    }
                    .keyboardShortcut("i", modifiers: .command)
                    toolbarButton("Code", systemImage: "chevron.left.forwardslash.chevron.right", help: "Inline code") {
                        handle.wrapSelection(prefix: "`", suffix: "`", placeholder: "code")
                    }
                    toolbarButton("Block", systemImage: "curlybraces", help: "Code block") {
                        handle.insertCodeBlock()
                    }
                    verticalDivider
                    toolbarButton("List", systemImage: "list.bullet", help: "Bulleted list") {
                        handle.prefixSelectedLines(with: "- ", placeholder: "item")
                    }
                    toolbarButton("Task", systemImage: "checklist", help: "Task list") {
                        handle.prefixSelectedLines(with: "- [ ] ", placeholder: "todo")
                    }
                    toolbarButton("Quote", systemImage: "quote.opening", help: "Blockquote") {
                        handle.prefixSelectedLines(with: "> ", placeholder: "quote")
                    }
                    verticalDivider
                    linkMenu
                    imageMenu
                }
                .padding(.vertical, 8)
                .padding(.leading, 8)
            }

            Button {
                withAnimation(.smooth(duration: 0.18)) {
                    showPreview.toggle()
                }
            } label: {
                MarkdownToolbarChip(
                    title: showPreview ? "Hide" : "Preview",
                    systemImage: showPreview ? "eye.slash" : "eye",
                    isActive: showPreview
                )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .help("Markdown preview")
        }
    }

    private var editorPane: some View {
        let attachments = MarkdownAttachmentRef.extract(from: text)
        return VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                PromptEditorWithAutocomplete(
                    text: $text,
                    files: files,
                    slashes: slashes,
                    handle: handle,
                    minHeight: showPreview ? 430 : 520,
                    emptyTabInsertion: starterTemplate,
                    droppedItemFormatter: formatDroppedItems(_:)
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Write the task as a real spec.")
                            .font(WFFont.hand(17, weight: .bold))
                            .foregroundStyle(WF.ink2)
                        Text("\(starterTemplate)\n\nPress Tab to insert this template. Drag an image, paste a URL, type @ for files or / for skills.")
                            .font(WFFont.mono(12))
                            .foregroundStyle(WF.ink3)
                            .lineSpacing(4)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !attachments.isEmpty {
                Rectangle()
                    .fill(WF.line.opacity(0.16))
                    .frame(height: 1)
                MarkdownAttachmentShelf(
                    attachments: attachments,
                    repoPath: repoPath,
                    isExpanded: $areAttachmentsExpanded,
                    onDelete: deleteAttachment(_:)
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: showPreview ? 430 : 520, maxHeight: .infinity)
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 12))
                Text("Markdown preview")
                    .font(WFFont.hand(12, weight: .bold))
                Spacer()
            }
            .foregroundStyle(WF.ink2)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            MarkdownPreview(text: text, repoPath: repoPath)
        }
        .frame(maxHeight: .infinity)
        .background(WF.paper.opacity(0.62))
    }

    private var linkMenu: some View {
        Menu {
            Button("Paste Link from Clipboard") {
                insertClipboardLink()
            }
            Button("Blank Link") {
                handle.insertMarkdownLink(destination: "https://", selectDestination: true)
            }
        } label: {
            MarkdownToolbarChip(title: "Link", systemImage: "link")
        }
        .menuStyle(.borderlessButton)
        .help("Insert Markdown link")
    }

    private var imageMenu: some View {
        Menu {
            Button("Choose Image…") {
                chooseImageFile()
            }
            Button("Paste Image URL from Clipboard") {
                insertClipboardImage()
            }
            Button("Blank Image") {
                handle.insertMarkdownImage(alt: "image", source: "path-or-url", selectSource: true)
            }
        } label: {
            MarkdownToolbarChip(title: "Image", systemImage: "photo")
        }
        .menuStyle(.borderlessButton)
        .help("Insert Markdown image")
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(WF.line.opacity(0.18))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 2)
    }

    private func toolbarButton(
        _ title: String,
        systemImage: String? = nil,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            MarkdownToolbarChip(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Link / image insertion

    private func chooseImageFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.title = "Choose an image for the prompt"
        panel.prompt = "Insert"
        if panel.runModal() == .OK, let url = panel.url {
            insertImage(url: url)
        }
    }

    private func insertClipboardLink() {
        guard let raw = clipboardURLText,
              let insertion = formatTextDrop(raw) else {
            handle.insertMarkdownLink(destination: "https://", selectDestination: true)
            return
        }
        handle.insert(insertion)
    }

    private func insertClipboardImage() {
        guard let raw = clipboardURLText,
              let insertion = formatTextDrop(raw, preferImage: true) else {
            handle.insertMarkdownImage(alt: "image", source: "path-or-url", selectSource: true)
            return
        }
        handle.insert(insertion)
    }

    private var clipboardURLText: String? {
        guard let raw = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if URL(string: raw)?.scheme != nil { return raw }
        if raw.hasPrefix("/"), FileManager.default.fileExists(atPath: raw) { return raw }
        return nil
    }

    private func insertImage(url: URL) {
        handle.insert(imageInsertion(url: url))
    }

    private func insertLink(url: URL) {
        handle.insert(linkInsertion(url: url))
    }

    private func insertURLString(_ raw: String) {
        if let insertion = formatTextDrop(raw) {
            handle.insert(insertion)
        } else {
            handle.insertText(raw)
        }
    }

    private func deleteAttachment(_ attachment: MarkdownAttachmentRef) {
        withAnimation(.smooth(duration: 0.16)) {
            text = MarkdownAttachmentRef.remove(attachment, from: text)
        }
    }

    private func formatDroppedItems(_ items: [PromptDroppedItem]) -> PromptTextInsertion? {
        var inlineParts: [String] = []
        var definitions: [String] = []
        var reserved = Set<String>()

        for item in items {
            guard let insertion = insertion(for: item, reserved: &reserved) else {
                continue
            }
            inlineParts.append(insertion.text)
            if let appendix = insertion.appendix {
                definitions.append(appendix)
            }
        }

        guard !inlineParts.isEmpty else { return nil }
        return PromptTextInsertion(
            text: inlineParts.joined(separator: "\n"),
            appendix: definitions.isEmpty ? nil : definitions.joined(separator: "\n")
        )
    }

    private func insertion(
        for item: PromptDroppedItem,
        reserved: inout Set<String>
    ) -> PromptTextInsertion? {
        switch item {
        case .file(let url):
            return isImageURL(url)
                ? imageInsertion(url: url, reserved: &reserved)
                : linkInsertion(url: url, reserved: &reserved)
        case .url(let url):
            return isImageURL(url)
                ? imageInsertion(url: url, reserved: &reserved)
                : linkInsertion(url: url, reserved: &reserved)
        case .text(let raw):
            return formatTextDrop(raw, preferImage: false, reserved: &reserved)
        }
    }

    private func formatTextDrop(
        _ raw: String,
        preferImage: Bool = false
    ) -> PromptTextInsertion? {
        var reserved = Set<String>()
        return formatTextDrop(raw, preferImage: preferImage, reserved: &reserved)
    }

    private func formatTextDrop(
        _ raw: String,
        preferImage: Bool,
        reserved: inout Set<String>
    ) -> PromptTextInsertion? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }

        if let url = URL(string: trimmed), url.scheme != nil {
            if preferImage || isImageURL(url) {
                return imageInsertion(url: url, reserved: &reserved)
            }
            return linkInsertion(url: url, reserved: &reserved)
        }

        if FileManager.default.fileExists(atPath: trimmed) {
            let url = URL(fileURLWithPath: trimmed)
            return (preferImage || isImageURL(url))
                ? imageInsertion(url: url, reserved: &reserved)
                : linkInsertion(url: url, reserved: &reserved)
        }

        return nil
    }

    private func imageInsertion(url: URL) -> PromptTextInsertion {
        var reserved = Set<String>()
        return imageInsertion(url: url, reserved: &reserved)
    }

    private func imageInsertion(url: URL, reserved: inout Set<String>) -> PromptTextInsertion {
        let source = markdownDestination(pathForMarkdown(url))
        let alt = cleanMarkdownLabel(url.deletingPathExtension().lastPathComponent, fallback: "image")
        let id = nextReferenceID(prefix: "image", reserved: &reserved)
        return PromptTextInsertion(
            text: "![\(alt)][\(id)]",
            appendix: "[\(id)]: \(source)"
        )
    }

    private func linkInsertion(url: URL) -> PromptTextInsertion {
        var reserved = Set<String>()
        return linkInsertion(url: url, reserved: &reserved)
    }

    private func linkInsertion(url: URL, reserved: inout Set<String>) -> PromptTextInsertion {
        let destination = markdownDestination(pathForMarkdown(url))
        let label = cleanMarkdownLabel(linkLabel(for: url), fallback: "link")
        let id = nextReferenceID(prefix: url.isFileURL ? "file" : "link", reserved: &reserved)
        return PromptTextInsertion(
            text: "[\(label)][\(id)]",
            appendix: "[\(id)]: \(destination)"
        )
    }

    private func linkLabel(for url: URL) -> String {
        if url.isFileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        if let host = url.host, !host.isEmpty {
            let path = url.path
            if path.isEmpty || path == "/" { return host }
            let last = url.deletingPathExtension().lastPathComponent
            return last.isEmpty ? host : "\(host)/\(last)"
        }
        return url.absoluteString
    }

    private func nextReferenceID(prefix: String, reserved: inout Set<String>) -> String {
        var index = 1
        while true {
            let id = "\(prefix)-\(index)"
            let alreadyInText = text.contains("[\(id)]") || text.contains("[\(id)]:")
            if !alreadyInText && !reserved.contains(id) {
                reserved.insert(id)
                return id
            }
            index += 1
        }
    }

    private func cleanMarkdownLabel(_ raw: String, fallback: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return fallback }
        if cleaned.count <= 48 { return cleaned }
        return String(cleaned.prefix(45)) + "..."
    }

    private func pathForMarkdown(_ url: URL) -> String {
        guard url.isFileURL else { return url.absoluteString }
        let path = (url.path as NSString).standardizingPath
        let base = (repoPath as NSString).standardizingPath
        if !base.isEmpty {
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) {
                return String(path.dropFirst(prefix.count))
            }
        }
        return path
    }

    private func markdownDestination(_ raw: String) -> String {
        if raw.hasPrefix("<"), raw.hasSuffix(">") { return raw }
        let unsafe = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "()"))
        if raw.rangeOfCharacter(from: unsafe) != nil {
            return "<\(raw)>"
        }
        return raw
    }

    private func isImageURL(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Drop

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async {
                        if isImageURL(url) {
                            insertImage(url: url)
                        } else {
                            insertLink(url: url)
                        }
                    }
                }
                return true
            }
        }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.url.identifier) { data, _ in
                    guard let data,
                          let raw = String(data: data, encoding: .utf8) else { return }
                    DispatchQueue.main.async {
                        insertURLString(raw)
                    }
                }
                return true
            }
        }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                    guard let data,
                          let raw = String(data: data, encoding: .utf8) else { return }
                    DispatchQueue.main.async {
                        insertURLString(raw)
                    }
                }
                return true
            }
        }

        return false
    }
}

// MARK: - Editor attachments

private struct MarkdownAttachmentRef: Identifiable, Equatable {
    enum Kind {
        case image
        case link
    }

    let id: String
    let kind: Kind
    let label: String
    let source: String
    let inlineRange: NSRange
    let definitionRange: NSRange?

    static func extract(from markdown: String) -> [MarkdownAttachmentRef] {
        let ns = markdown as NSString
        let definitions = referenceDefinitions(in: markdown)
        var refs: [MarkdownAttachmentRef] = []

        if let regex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\((<[^>]+>|[^)]+)\)"#) {
            refs.append(contentsOf: regex.matches(
                in: markdown,
                range: NSRange(location: 0, length: ns.length)
            ).compactMap { match in
                guard match.numberOfRanges == 3 else { return nil }
                let label = ns.substring(with: match.range(at: 1))
                let source = cleanSource(ns.substring(with: match.range(at: 2)))
                return make(kind: .image, label: label, source: source, inlineRange: match.range, definitionRange: nil)
            })
        }

        if let regex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\[([^\]]+)\]"#) {
            refs.append(contentsOf: regex.matches(
                in: markdown,
                range: NSRange(location: 0, length: ns.length)
            ).compactMap { match in
                guard match.numberOfRanges == 3 else { return nil }
                let label = ns.substring(with: match.range(at: 1))
                let key = ns.substring(with: match.range(at: 2))
                guard let definition = definitions[key] else { return nil }
                return make(
                    kind: .image,
                    label: label,
                    source: definition.source,
                    inlineRange: match.range,
                    definitionRange: definition.range
                )
            })
        }

        if let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\((<[^>]+>|[^)]+)\)"#) {
            refs.append(contentsOf: regex.matches(
                in: markdown,
                range: NSRange(location: 0, length: ns.length)
            ).compactMap { match in
                guard match.numberOfRanges == 3,
                      !isImageSyntax(in: ns, matchRange: match.range) else { return nil }
                let label = ns.substring(with: match.range(at: 1))
                let source = cleanSource(ns.substring(with: match.range(at: 2)))
                return make(kind: .link, label: label, source: source, inlineRange: match.range, definitionRange: nil)
            })
        }

        if let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\[([^\]]+)\]"#) {
            refs.append(contentsOf: regex.matches(
                in: markdown,
                range: NSRange(location: 0, length: ns.length)
            ).compactMap { match in
                guard match.numberOfRanges == 3,
                      !isImageSyntax(in: ns, matchRange: match.range) else { return nil }
                let label = ns.substring(with: match.range(at: 1))
                let key = ns.substring(with: match.range(at: 2))
                guard let definition = definitions[key] else { return nil }
                return make(
                    kind: .link,
                    label: label,
                    source: definition.source,
                    inlineRange: match.range,
                    definitionRange: definition.range
                )
            })
        }

        return refs.sorted { $0.inlineRange.location < $1.inlineRange.location }
    }

    static func remove(_ attachment: MarkdownAttachmentRef, from markdown: String) -> String {
        let ns = markdown as NSString
        var deletionRanges: [NSRange] = []

        if let definitionRange = attachment.definitionRange {
            deletionRanges.append(ns.paragraphRange(for: definitionRange))
        }

        let paragraphRange = ns.paragraphRange(for: attachment.inlineRange)
        let relativeInline = NSRange(
            location: attachment.inlineRange.location - paragraphRange.location,
            length: attachment.inlineRange.length
        )
        let paragraph = ns.substring(with: paragraphRange) as NSString
        let afterInlineRemoval = paragraph
            .replacingCharacters(in: relativeInline, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        deletionRanges.append(afterInlineRemoval.isEmpty ? paragraphRange : attachment.inlineRange)

        let mutable = NSMutableString(string: markdown)
        for range in deletionRanges.sorted(by: { $0.location > $1.location }) {
            guard range.location >= 0,
                  range.location + range.length <= mutable.length else { continue }
            mutable.deleteCharacters(in: range)
        }

        var result = mutable as String
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result
    }

    private static func make(
        kind: Kind,
        label: String,
        source: String,
        inlineRange: NSRange,
        definitionRange: NSRange?
    ) -> MarkdownAttachmentRef {
        let safeLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return MarkdownAttachmentRef(
            id: "\(kind)-\(inlineRange.location)-\(inlineRange.length)-\(source)",
            kind: kind,
            label: safeLabel.isEmpty ? (kind == .image ? "image" : "link") : safeLabel,
            source: source,
            inlineRange: inlineRange,
            definitionRange: definitionRange
        )
    }

    private static func referenceDefinitions(in markdown: String) -> [String: (source: String, range: NSRange)] {
        let pattern = #"(?m)^\[([^\]]+)\]:\s*(<[^>]+>|\S+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let ns = markdown as NSString
        let matches = regex.matches(
            in: markdown,
            range: NSRange(location: 0, length: ns.length)
        )
        var definitions: [String: (source: String, range: NSRange)] = [:]
        for match in matches where match.numberOfRanges == 3 {
            let key = ns.substring(with: match.range(at: 1))
            definitions[key] = (cleanSource(ns.substring(with: match.range(at: 2))), match.range)
        }
        return definitions
    }

    private static func isImageSyntax(in ns: NSString, matchRange: NSRange) -> Bool {
        guard matchRange.location > 0 else { return false }
        return ns.substring(with: NSRange(location: matchRange.location - 1, length: 1)) == "!"
    }

    private static func cleanSource(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct MarkdownAttachmentShelf: View {
    let attachments: [MarkdownAttachmentRef]
    let repoPath: String
    @Binding var isExpanded: Bool
    var onDelete: (MarkdownAttachmentRef) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.smooth(duration: 0.16)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Image(systemName: "paperclip")
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(attachments.count) attachments")
                            .font(WFFont.mono(11))
                    }
                    .foregroundStyle(WF.ink2)
                }
                .buttonStyle(.plain)

                Spacer()

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments.prefix(6)) { attachment in
                            MarkdownAttachmentMiniChip(
                                attachment: attachment,
                                repoPath: repoPath,
                                onDelete: { onDelete(attachment) }
                            )
                        }
                    }
                }
                .frame(maxWidth: 520)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            if isExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(attachments) { attachment in
                            MarkdownAttachmentCard(
                                attachment: attachment,
                                repoPath: repoPath,
                                onDelete: { onDelete(attachment) }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
        }
        .background(WF.paper.opacity(0.54))
    }
}

private struct MarkdownAttachmentMiniChip: View {
    let attachment: MarkdownAttachmentRef
    let repoPath: String
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            thumbnail
                .frame(width: 24, height: 24)
                .background(WF.paper, in: RoundedRectangle(cornerRadius: 5))
                .clipShape(RoundedRectangle(cornerRadius: 5))

            Text(attachment.label)
                .font(WFFont.mono(10))
                .foregroundStyle(WF.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 92)

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(WF.ink3)
            }
            .buttonStyle(.plain)
            .help("Remove this attachment")
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(WF.paperAlt, in: Capsule())
        .overlay(Capsule().stroke(WF.line.opacity(0.18), lineWidth: 1))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if attachment.kind == .image,
           let url = resolvedURL {
            if url.isFileURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        icon("photo")
                    }
                }
            }
        } else {
            icon(attachment.kind == .image ? "photo" : "link")
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(WF.ink3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resolvedURL: URL? {
        if let url = URL(string: attachment.source), url.scheme != nil {
            return url
        }
        if attachment.source.hasPrefix("/") {
            return URL(fileURLWithPath: attachment.source)
        }
        guard !repoPath.isEmpty else { return nil }
        return URL(fileURLWithPath: repoPath).appendingPathComponent(attachment.source)
    }
}

private struct MarkdownAttachmentCard: View {
    let attachment: MarkdownAttachmentRef
    let repoPath: String
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                media
                    .frame(width: 142, height: attachment.kind == .image ? 94 : 58)
                    .background(WF.paper, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(WF.line.opacity(0.32), lineWidth: 1)
                    )

                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(WF.paper)
                        .frame(width: 20, height: 20)
                        .background(WF.ink, in: Circle())
                        .overlay(Circle().stroke(WF.paper.opacity(0.85), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("Remove this attachment from the prompt")
            }

            Text(attachment.label)
                .font(WFFont.hand(12, weight: .bold))
                .foregroundStyle(WF.ink)
                .lineLimit(1)

            Text(shortSource)
                .font(WFFont.mono(9))
                .foregroundStyle(WF.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 142, alignment: .leading)
        }
        .padding(7)
        .background(WF.paperAlt, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(WF.line.opacity(0.4), lineWidth: 1))
    }

    @ViewBuilder
    private var media: some View {
        switch attachment.kind {
        case .image:
            if let url = resolvedURL {
                if url.isFileURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 142, height: 94)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ProgressView().controlSize(.small)
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 142, height: 94)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        case .failure:
                            placeholder(icon: "photo", label: "image")
                        @unknown default:
                            placeholder(icon: "photo", label: "image")
                        }
                    }
                }
            } else {
                placeholder(icon: "photo", label: "image")
            }
        case .link:
            placeholder(icon: resolvedURL?.isFileURL == true ? "doc.text" : "link", label: linkHost)
        }
    }

    private func placeholder(icon: String, label: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
            Text(label)
                .font(WFFont.mono(9))
                .lineLimit(1)
        }
        .foregroundStyle(WF.ink2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resolvedURL: URL? {
        if let url = URL(string: attachment.source), url.scheme != nil {
            return url
        }
        if attachment.source.hasPrefix("/") {
            return URL(fileURLWithPath: attachment.source)
        }
        guard !repoPath.isEmpty else { return nil }
        return URL(fileURLWithPath: repoPath).appendingPathComponent(attachment.source)
    }

    private var linkHost: String {
        guard let url = resolvedURL, !url.isFileURL else { return "file" }
        return url.host ?? "link"
    }

    private var shortSource: String {
        if let url = resolvedURL {
            if url.isFileURL {
                return url.lastPathComponent.isEmpty ? attachment.source : url.lastPathComponent
            }
            if let host = url.host {
                let last = url.deletingPathExtension().lastPathComponent
                return last.isEmpty ? host : "\(host)/\(last)"
            }
        }
        if attachment.source.count <= 42 { return attachment.source }
        return "..." + String(attachment.source.suffix(39))
    }
}

// MARK: - Markdown preview

private struct MarkdownPreview: View {
    let text: String
    let repoPath: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Preview appears as you write.")
                        .font(WFFont.hand(14))
                        .foregroundStyle(WF.ink3)
                } else {
                    Text(renderedMarkdown)
                        .font(.system(size: 13))
                        .foregroundStyle(WF.ink)
                        .lineSpacing(4)
                        .textSelection(.enabled)

                    let refs = imageRefs
                    if !refs.isEmpty {
                        Rectangle()
                            .fill(WF.line.opacity(0.18))
                            .frame(height: 1)
                        ForEach(refs) { ref in
                            MarkdownImageThumbnail(ref: ref, repoPath: repoPath)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var renderedMarkdown: AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    private var imageRefs: [MarkdownImageRef] {
        MarkdownImageRef.extract(from: text)
    }
}

private struct MarkdownImageRef: Identifiable {
    let id = UUID()
    let alt: String
    let source: String

    static func extract(from markdown: String) -> [MarkdownImageRef] {
        var refs: [MarkdownImageRef] = []
        let ns = markdown as NSString

        if let inlineRegex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\((<[^>]+>|[^)]+)\)"#) {
            let matches = inlineRegex.matches(
                in: markdown,
                range: NSRange(location: 0, length: ns.length)
            )
            refs.append(contentsOf: matches.compactMap { match in
                guard match.numberOfRanges == 3 else { return nil }
                let alt = ns.substring(with: match.range(at: 1))
                let source = cleanSource(ns.substring(with: match.range(at: 2)))
                return MarkdownImageRef(alt: alt, source: source)
            })
        }

        let definitions = referenceDefinitions(in: markdown)
        if let referenceRegex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\[([^\]]+)\]"#) {
            let matches = referenceRegex.matches(
                in: markdown,
                range: NSRange(location: 0, length: ns.length)
            )
            refs.append(contentsOf: matches.compactMap { match in
                guard match.numberOfRanges == 3 else { return nil }
                let alt = ns.substring(with: match.range(at: 1))
                let key = ns.substring(with: match.range(at: 2))
                guard let source = definitions[key] else { return nil }
                return MarkdownImageRef(alt: alt, source: source)
            })
        }

        return refs
    }

    private static func referenceDefinitions(in markdown: String) -> [String: String] {
        let pattern = #"(?m)^\[([^\]]+)\]:\s*(<[^>]+>|\S+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let ns = markdown as NSString
        let matches = regex.matches(
            in: markdown,
            range: NSRange(location: 0, length: ns.length)
        )
        var definitions: [String: String] = [:]
        for match in matches where match.numberOfRanges == 3 {
            let key = ns.substring(with: match.range(at: 1))
            definitions[key] = cleanSource(ns.substring(with: match.range(at: 2)))
        }
        return definitions
    }

    private static func cleanSource(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct MarkdownImageThumbnail: View {
    let ref: MarkdownImageRef
    let repoPath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 11))
                Text(ref.alt.isEmpty ? "image" : ref.alt)
                    .font(WFFont.hand(12, weight: .bold))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(WF.ink2)

            if let url = resolvedURL {
                if url.isFileURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 150)
                        .frame(maxWidth: .infinity)
                        .background(WF.paper, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity, minHeight: 96)
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 150)
                                .frame(maxWidth: .infinity)
                        case .failure:
                            unavailablePreview
                        @unknown default:
                            unavailablePreview
                        }
                    }
                }
            } else {
                unavailablePreview
            }

            Text(ref.source)
                .font(WFFont.mono(10))
                .foregroundStyle(WF.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(9)
        .background(WF.paperAlt.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(WF.line.opacity(0.35), lineWidth: 1))
    }

    private var unavailablePreview: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text("Preview unavailable")
        }
        .font(WFFont.hand(12))
        .foregroundStyle(WF.ink3)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(WF.paper, in: RoundedRectangle(cornerRadius: 8))
    }

    private var resolvedURL: URL? {
        if let url = URL(string: ref.source), url.scheme != nil {
            return url
        }
        if ref.source.hasPrefix("/") {
            return URL(fileURLWithPath: ref.source)
        }
        guard !repoPath.isEmpty else { return nil }
        return URL(fileURLWithPath: repoPath).appendingPathComponent(ref.source)
    }
}

#Preview {
    NewTaskSheet()
        .environment(AppState())
}
