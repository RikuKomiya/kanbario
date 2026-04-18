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
    }
}
