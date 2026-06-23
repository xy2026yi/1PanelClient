//
//  UnifiedWebsitesTab.swift
//  1PanelClient
//
//  统一网站 Tab：网站 + SSL 证书 通过分段控件切换
//  各子视图保留独立 NavigationStack，toolbar/sheet 状态独立
//

import SwiftUI

struct UnifiedWebsitesTab: View {
    @ObservedObject var manager: ServerManager
    @State private var selectedSegment = 0  // 0=网站, 1=证书

    var body: some View {
        VStack(spacing: 0) {
            Picker("网站视图", selection: $selectedSegment) {
                Text("网站").tag(0)
                Text("证书").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Group {
                if selectedSegment == 0 {
                    WebsitesTab(manager: manager, showCloseButton: false)
                } else {
                    CertificatesTab(manager: manager, showCloseButton: false)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: selectedSegment)
        }
    }
}
