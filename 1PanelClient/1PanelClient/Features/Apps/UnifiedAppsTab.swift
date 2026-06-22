//
//  UnifiedAppsTab.swift
//  1PanelClient
//
//  统一应用 Tab：已安装 + 商店 通过分段控件切换
//  各子视图保留独立 NavigationStack，搜索框/toolbar/sheet 状态独立
//

import SwiftUI

struct UnifiedAppsTab: View {
    @ObservedObject var manager: ServerManager
    @State private var selectedSegment = 0  // 0=已安装, 1=商店

    var body: some View {
        VStack(spacing: 0) {
            Picker("应用视图", selection: $selectedSegment) {
                Text("已安装").tag(0)
                Text("商店").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Group {
                if selectedSegment == 0 {
                    AppsTab(manager: manager)
                } else {
                    AppStoreTab(manager: manager)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: selectedSegment)
        }
    }
}
