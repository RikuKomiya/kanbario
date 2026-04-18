import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var isShowingNewTask = false

    var body: some View {
        HSplitView {
            KanbanBoardView()
                .frame(minWidth: 700, idealWidth: 900)
            TaskDetailView()
                .frame(minWidth: 280, idealWidth: 360)
                .frame(maxWidth: 500)
        }
        .frame(minWidth: 1000, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingNewTask = true
                } label: {
                    Label("New Task", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
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
