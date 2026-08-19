//
//  ContentView.swift
//  1PanelClient
//

import SwiftUI

struct ContentView: View {
    /// 语言切换时 +1，经 .id() 强制重建整棵视图树以即时生效
    /// （服务器数据在 ServerManager 单例中，不受重建影响）
    @State private var languageVersion = 0

    var body: some View {
        MainTabView()
            .id(languageVersion)
            .onReceive(NotificationCenter.default.publisher(for: L10n.languageDidChangeNotification)) { _ in
                languageVersion += 1
            }
    }
}

#Preview {
    ContentView()
}
