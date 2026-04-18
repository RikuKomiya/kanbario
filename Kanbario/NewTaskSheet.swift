import SwiftUI

/// 新規タスク追加用のモーダルシート。⌘N や Toolbar ボタンから呼ばれる。
struct NewTaskSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var bodyText: String = ""   // `body` は View の property と衝突するので rename

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Task")
                .font(.title2).bold()

            VStack(alignment: .leading, spacing: 4) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("1 行要約 (例: Fix login bug)", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Task body (Claude への初回プロンプト)")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $bodyText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3))
                    )
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    appState.addTask(title: title, body: bodyText)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 300)
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
