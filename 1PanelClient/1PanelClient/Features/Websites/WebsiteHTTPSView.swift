//
//  WebsiteHTTPSView.swift
//  1PanelClient
//

import SwiftUI

// MARK: - TLS 协议 Pills

struct FlowingTLSPills: View {
    @Binding var selected: Set<String>

    private let allProtocols: [(key: String, label: String)] = [
        ("TLSv1.3", "TLS 1.3"),
        ("TLSv1.2", "TLS 1.2"),
        ("TLSv1.1", "TLS 1.1"),
        ("TLSv1",   "TLS 1.0"),
    ]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(allProtocols, id: \.key) { p in
                let isEnabled = selected.contains(p.key)
                Button {
                    if isEnabled {
                        selected.remove(p.key)
                    } else {
                        selected.insert(p.key)
                    }
                } label: {
                    HStack(spacing: 3) {
                        if isEnabled {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                        }
                        Text(p.label)
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        isEnabled ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.1)
                    )
                    .foregroundStyle(isEnabled ? .blue : .secondary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - HTTPS 配置

struct WebsiteHTTPSView: View {
    let websiteId: Int
    @ObservedObject var vm: WebsitesViewModel

    @State private var config: WebsiteHTTPS?
    @State private var isLoading = false
    @State private var isSaving = false
    /// 轻量成功提示（自动消失，仅在 HTTPS 页显示，避免返回主页面时弹窗残留）
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    // 可编辑状态
    @State private var enable = false
    @State private var httpConfig = "HTTPToHTTPS"
    @State private var hsts = false
    @State private var hstsIncludeSubDomains = true
    @State private var http3 = false
    @State private var sslProtocol: Set<String> = ["TLSv1.3", "TLSv1.2"]
    @State private var algorithm = ""
    @State private var selectedSSLId = 0
    @State private var httpsPort = ""
    // 从响应里读取的当前证书 ID，保存时若用户未修改则用它
    @State private var originalSSLId = 0

    private let availableProtocols = ["TLSv1.3", "TLSv1.2", "TLSv1.1", "TLSv1"]
    private let availableHttpConfigs = [
        ("HTTPToHTTPS", L10n.t("HTTP 自动跳转 HTTPS")),
        ("HTTPOnly",    L10n.t("仅 HTTP")),
        ("HTTPSOnly",   L10n.t("仅 HTTPS")),
    ]

    var body: some View {
        Group {
            if isLoading {
                ProgressView(L10n.t("加载 HTTPS 配置…"))
            } else {
                editor
            }
        }
        .navigationTitle("HTTPS")
        .navigationBarTitleDisplayMode(.inline)
        .toastOverlay(message: $toastMessage)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(isSaving)
            }
        }
        .task {
            await load()
            await vm.loadSSLCerts()
            // 证书列表加载完成后选中当前证书
            selectedSSLId = originalSSLId
        }
    }

    private var editor: some View {
        Form {
            Section(L10n.t("基本")) {
                Toggle(L10n.t("启用 HTTPS"), isOn: $enable)
                if enable {
                    Picker(L10n.t("HTTP 配置"), selection: $httpConfig) {
                        ForEach(availableHttpConfigs, id: \.0) { v in
                            Text(v.1).tag(v.0)
                        }
                    }
                    HStack {
                        Text(L10n.t("HTTPS 端口"))
                        Spacer()
                        TextField(L10n.t("端口"), text: $httpsPort)
                            .keyboardType(.numberPad)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            if enable {
                Section(L10n.t("SSL 证书")) {
                    Picker(L10n.t("选择证书"), selection: $selectedSSLId) {
                        ForEach(vm.availableSSLs) { ssl in
                            VStack(alignment: .leading) {
                                Text(ssl.displayName)
                                Text(L10n.f("有效期至 %@", ssl.displayExpireDate))
                                    .font(.caption2)
                                    .foregroundStyle(ssl.isExpired ? .red : .secondary)
                            }
                            .tag(ssl.id)
                        }
                    }
                }

                Section(L10n.t("支持的协议版本")) {
                    FlowingTLSPills(selected: $sslProtocol)
                }

                Section(L10n.t("高级")) {
                    Toggle("HTTP/3 (QUIC)", isOn: $http3)
                    Toggle("HSTS", isOn: $hsts)
                    if hsts {
                        Toggle(L10n.t("HSTS 包含子域名"), isOn: $hstsIncludeSubDomains)
                    }
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let c = await vm.loadHTTPSConfig(id: websiteId) else { return }
        config = c
        enable = c.enable ?? false
        httpConfig = c.httpConfig ?? "HTTPToHTTPS"
        hsts = c.hsts ?? false
        hstsIncludeSubDomains = c.hstsIncludeSubDomains ?? true
        http3 = c.http3 ?? false
        sslProtocol = Set(c.sslProtocol ?? ["TLSv1.3", "TLSv1.2"])
        algorithm = c.algorithm ?? ""
        httpsPort = c.httpsPort ?? ""
        // 关键：保存响应里的当前证书 ID，保存时若用户未改证书则用它
        originalSSLId = c.currentSSLId
        // 默认显示当前使用证书
        selectedSSLId = c.currentSSLId
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let sslId = selectedSSLId == 0 ? originalSSLId : selectedSSLId
        let req = WebsiteHTTPSUpdateRequest(
            enable: enable,
            websiteId: websiteId,
            websiteSSLId: sslId,
            httpConfig: httpConfig,
            hsts: hsts,
            hstsIncludeSubDomains: hstsIncludeSubDomains,
            algorithm: algorithm,
            sslProtocol: Array(sslProtocol),
            httpsPort: httpsPort,
            http3: http3
        )
        let ok = await vm.updateHTTPSConfig(websiteId: websiteId, sslId: sslId, req: req)
        if ok {
            showToast(L10n.t("HTTPS 配置已保存，正在重载 OpenResty…"))
        }
        await load()
    }

    /// 显示轻量提示，2 秒后自动消失
    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { toastMessage = nil }
        }
    }
}

