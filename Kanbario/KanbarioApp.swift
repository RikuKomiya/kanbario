//
//  KanbarioApp.swift
//  Kanbario
//
//  Created by 小宮陸 on 2026/04/18.
//

import SwiftUI

@main
struct KanbarioApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
        // `.hiddenTitleBar` は一部 macOS で HSplitView とレイアウトが崩れるので、
        // 通常のタイトルバー + unified toolbar style を使う。
        .windowToolbarStyle(.unified)
        // **New Task ⌘N:** KanbanBoardView のボタン側にも
        // `.keyboardShortcut("n")` は付いているが、詳細モーダル表示中 /
        // フォーカスがボード外にある時は効かない。App レベルの
        // CommandGroup(replacing: .newItem) にハンドラを載せれば、
        // ウィンドウがアクティブな限りどこからでも ⌘N で発火する。
        // 既に sheet が開いている場合も showingNewTaskSheet = true は
        // idempotent なので二重表示にはならない。
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Task") {
                    appState.showingNewTaskSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(appState.showingNewTaskSheet)
            }
        }
    }
}
