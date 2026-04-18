import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var isShowingNewTask = false

    var body: some View {
        HSplitView {
            KanbanBoardView()
                .frame(minWidth: 760, idealWidth: 960)
            TaskDetailView()
                .frame(minWidth: 300, idealWidth: 360)
                .frame(maxWidth: 520)
        }
        .frame(minWidth: 1060, minHeight: 580)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingNewTask = true
                } label: {
                    Label("New Task", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New Task (⌘N)")
            }
        }
        .sheet(isPresented: $isShowingNewTask) {
            NewTaskSheet()
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
