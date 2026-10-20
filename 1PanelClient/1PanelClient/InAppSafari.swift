//
//  InAppSafari.swift
//  1PanelClient
//
//  应用内浏览器：SFSafariViewController——与 Safari 共享 Cookie/登录态，页面在独立
//  进程渲染，App 代码不可见页面内容。全局路由 InAppSafariPresenter 由 ContentView
//  持有并挂 sheet，任意页面经 environmentObject 调 open(url) 弹出；工具栏提供
//  「在 Safari 中打开」跳出真身。
//  仅 http/https 走应用内（无 scheme 的裸域名补 https，其他 scheme 回落系统处理）；
//  OAuth 授权页与 IPA 下载页不适用（复制 code / 下载管理依赖真实 Safari），仍直跳。
//

import Combine
import SafariServices
import SwiftUI

/// 应用内浏览器路由：ContentView 持有并挂 sheet；任何页面 `safari.open(url)` 即弹出
@MainActor
final class InAppSafariPresenter: ObservableObject {
    @Published var target: SafariTarget?

    /// 非 http(s) 链接的出路（面板 API 的 website/document 字段可能带脏 scheme，
    /// 交给系统按注册的 handler 处理；测试注入用）
    private let openExternal: (URL) -> Void

    init(openExternal: @escaping (URL) -> Void = { UIApplication.shared.open($0) }) {
        self.openExternal = openExternal
    }

    /// 应用内打开：http/https 弹应用内浏览器；裸域名补 https；其他 scheme 交系统
    func open(_ url: URL) {
        var url = url
        if url.scheme == nil, let fixed = URL(string: "https://" + url.absoluteString) {
            url = fixed
        }
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            target = SafariTarget(url: url)
        } else {
            openExternal(url)
        }
    }

    func close() {
        target = nil
    }
}

/// sheet(item:) 的呈现目标（URL 需 Identifiable）
struct SafariTarget: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// SFSafariViewController 的 SwiftUI 包装
private struct SafariViewControllerRep: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

/// 浏览器 sheet：SFS 视图 + 自有工具栏（关闭 / 在 Safari 中打开，不依赖系统分享面板）
struct InAppSafariSheet: View {
    let target: SafariTarget
    @EnvironmentObject private var presenter: InAppSafariPresenter
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            SafariViewControllerRep(url: target.url)
                .navigationTitle(target.url.host ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.t("关闭")) { presenter.close() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            openURL(target.url)
                        } label: {
                            Label(L10n.t("在 Safari 中打开"), systemImage: "safari")
                        }
                    }
                }
        }
    }
}
