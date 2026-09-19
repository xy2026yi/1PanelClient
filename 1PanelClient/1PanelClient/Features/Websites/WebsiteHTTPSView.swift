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

    /// 证书选项键（OutlinedPicker 用 String）：0=未选择；当前证书不在列表时 cur-{id} 兜底，
    /// 列表就绪后自动并回真实选项
    private var certOptionKeys: [String] {
        var keys = ["0"]
        if selectedSSLId != 0, !vm.availableSSLs.contains(where: { $0.id == selectedSSLId }) {
            keys.append("cur-\(selectedSSLId)")
        }
        keys += vm.availableSSLs.map { String($0.id) }
        return keys
    }

    private var certOptionLabels: [String: String] {
        var labels = ["0": L10n.t("未选择")]
        if selectedSSLId != 0, !vm.availableSSLs.contains(where: { $0.id == selectedSSLId }) {
            if let domain = config?.ssl?.primaryDomain, !domain.isEmpty {
                labels["cur-\(selectedSSLId)"] = L10n.f("当前证书：%@", domain)
            } else {
                labels["cur-\(selectedSSLId)"] = L10n.f("当前证书（ID %ld）", selectedSSLId)
            }
        }
        for ssl in vm.availableSSLs {
            labels[String(ssl.id)] = ssl.displayName
        }
        return labels
    }

    private var certOutlinedBinding: Binding<String> {
        Binding<String>(
            get: {
                if selectedSSLId == 0 { return "0" }
                return vm.availableSSLs.contains(where: { $0.id == selectedSSLId })
                    ? String(selectedSSLId) : "cur-\(selectedSSLId)"
            },
            set: { key in
                if key == "0" {
                    selectedSSLId = 0
                } else if key.hasPrefix("cur-") {
                    selectedSSLId = Int(key.dropFirst(4)) ?? selectedSSLId
                } else {
                    selectedSSLId = Int(key) ?? selectedSSLId
                }
            }
        )
    }

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
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
            // 默认显示当前使用证书；不在可选列表时由选择器的「当前证书」兜底行接住
            selectedSSLId = originalSSLId
        }
        .refreshable { await load() }
    }

    private var editor: some View {
        Form {
            Section(L10n.t("基本")) {
                Toggle(L10n.t("启用"), isOn: $enable)
                if enable {
                    OutlinedPicker(label: L10n.t("HTTP 配置"),
                                   options: availableHttpConfigs.map(\.0),
                                   selection: $httpConfig,
                                   optionLabels: Dictionary(uniqueKeysWithValues:
                                       availableHttpConfigs.map { ($0.0, $0.1) }))
                    FormTextField(label: L10n.t("HTTPS 端口"), prompt: "443",
                                  text: $httpsPort, keyboardType: .numberPad)
                }
            }

            if enable {
                Section(L10n.t("SSL 证书")) {
                    OutlinedPicker(label: L10n.t("证书"),
                                   options: certOptionKeys,
                                   selection: certOutlinedBinding,
                                   optionLabels: certOptionLabels)
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
        // 服务端对未开启过 HTTPS 的站点会返回空串 httpConfig，
        // 不在选项内会让 Picker 报 invalid selection，回落默认值
        let rawHttpConfig = c.httpConfig ?? ""
        httpConfig = availableHttpConfigs.map(\.0).contains(rawHttpConfig) ? rawHttpConfig : "HTTPToHTTPS"
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

