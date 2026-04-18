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
    }
}
