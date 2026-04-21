import SwiftUI

/// 新規タスクの planning カードを作るシート。wireframe の MVPCard (planning 段階)
/// を後で正しく描画できるよう、tag / risk / owner / prompt version / needs を
/// 任意入力できる。どれも省略可能 — 最低限は title + body があれば作れる。
struct NewTaskSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var tag: LLMTag? = nil
    @State private var risk: RiskLevel? = nil
    @State private var owner: String = ""
    @State private var promptV: String = ""
    @State private var needsInput: String = ""   // カンマ区切り

    @FocusState private var focus: Field?
    enum Field { case title, body, owner, promptV, needs }

    var body: some View {
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

            needsField

            actionRow
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 560)
        .background(WF.paper)
        .foregroundStyle(WF.ink)  // 子孫の system TextField 等がダークモード時に白文字になるのを防止
        .tint(WF.ink)              // カーソル / selection も ink 色へ揃える
        .preferredColorScheme(.light)  // 紙色テーマは light 前提
        .onAppear { focus = .title }
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
            Hand("Title", size: 12, color: WF.ink2)
            TextField("1 行要約 (例: Fix login bug)", text: $title)
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
            Hand("Claude prompt", size: 12, color: WF.ink2)
            TextEditor(text: $bodyText)
                .font(WFFont.mono(12))
                .foregroundStyle(WF.ink)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(WF.paperAlt)
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(focus == .body ? WF.accent : WF.line, lineWidth: 1.3)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .focused($focus, equals: .body)
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

    /// title と body 両方が非空 + whitespace のみでないこと。
    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

#Preview {
    NewTaskSheet()
        .environment(AppState())
}
