import SwiftUI

/// 新規タスク追加用のモーダルシート。⌘N や Toolbar ボタンから呼ばれる。
struct NewTaskSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var bodyText: String = ""   // `body` は View の property と衝突するので rename

    @FocusState private var focus: Field?
    enum Field { case title, body }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("New Task", systemImage: "plus.square.fill.on.square.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Title")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("1 行要約 (例: Fix login bug)", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .title)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Claude prompt")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $bodyText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(.textBackgroundColor))
                    .frame(minHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(focus == .body ? Color.accentColor.opacity(0.5) : Color.black.opacity(0.12),
                                    lineWidth: focus == .body ? 2 : 1)
                    )
                    .focused($focus, equals: .body)
                    .animation(.smooth(duration: 0.15), value: focus)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button("Save") {
                    withAnimation(.smooth(duration: 0.3)) {
                        appState.addTask(title: title, body: bodyText)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isValid)
            }
        }
        .padding(22)
        .frame(minWidth: 520, minHeight: 340)
        .background(Color(.windowBackgroundColor))
        .onAppear { focus = .title }
    }

    /// Save ボタンを有効化する条件。
    /// title と body の両方が「非空 + whitespace-only でない」時のみ有効。
    /// Claude 初回プロンプトが空にならないことを保証する (claude "" の挙動は未検証で safer に倒した)。
    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

#Preview {
    NewTaskSheet()
        .environment(AppState())
}
