//
//  WebsiteProxiesView.swift
//  1PanelClient
//

import SwiftUI

// MARK: - 反向代理路由

struct WebsiteProxiesView: View {
    let websiteId: Int
    @ObservedObject var vm: WebsitesViewModel

    @State private var proxies: [WebsiteProxy] = []
    @State private var isLoading = false
    /// 列表加载失败（渲染页内错误态 + 重试）
    @State private var loadError: String?
    @State private var showEditSheet = false
    @State private var editingProxy: WebsiteProxy?
    @State private var showSourceSheet = false
    @State private var sourceProxy: WebsiteProxy?
    @State private var togglingProxyId: String?
    @State private var actionProxy: WebsiteProxy?
    @State private var pendingDeleteProxy: WebsiteProxy?

    var body: some View {
        Group {
            if isLoading && proxies.isEmpty {
                LoadingStateView()
            } else if let err = loadError, proxies.isEmpty {
                LoadErrorStateView(message: err) {
                    Task { await load() }
                }
            } else if proxies.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无反向代理"),
                    systemImage: "arrow.left.arrow.right",
                    description: Text(L10n.t("点击右上角创建第一个反向代理路由"))
                )
            } else {
                list
            }
        }
        .navigationTitle(L10n.t("反向代理"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingProxy = nil
                    showEditSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("添加反向代理"))
            }
        }
        .task {
            await load()
        }
        .navigationDestination(isPresented: $showEditSheet) {
            WebsiteProxyEditView(
                websiteId: websiteId,
                proxy: editingProxy,
                vm: vm
            ) {
                Task { await load() }
            }
        }
        .navigationDestination(isPresented: $showSourceSheet) {
            if let p = sourceProxy {
                WebsiteProxySourceView(websiteId: websiteId, proxy: p, vm: vm)
            }
        }
        .sheet(isPresented: Binding(
            get: { actionProxy != nil },
            set: { if !$0 { actionProxy = nil } }
        )) {
            ActionBottomSheet(
                title: actionProxy?.displayName ?? L10n.t("反向代理"),
                items: [
                    ActionMenuItem(
                        title: actionProxy?.enable == true ? L10n.t("关闭") : L10n.t("开启"),
                        icon: actionProxy?.enable == true ? "stop.fill" : "play.fill",
                        color: actionProxy?.enable == true ? .orange : .green
                    ) {
                        let proxy = actionProxy
                        Task { if let proxy { await toggleProxy(proxy) } }
                    },
                    ActionMenuItem(title: L10n.t("编辑"), icon: "pencil", color: .blue) {
                        editingProxy = actionProxy
                        showEditSheet = true
                    },
                    ActionMenuItem(title: L10n.t("源文"), icon: "doc.text", color: .teal) {
                        sourceProxy = actionProxy
                        showSourceSheet = true
                    },
                    ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
                        pendingDeleteProxy = actionProxy
                    },
                ],
                onDismiss: { actionProxy = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: 4))])
            .presentationDragIndicator(.visible)
        }
        .alert(
            L10n.t("删除"),
            isPresented: Binding(
                get: { pendingDeleteProxy != nil },
                set: { if !$0 { pendingDeleteProxy = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingDeleteProxy = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                if let proxy = pendingDeleteProxy {
                    Task { await deleteProxy(proxy) }
                }
                pendingDeleteProxy = nil
            }
        } message: {
            if let proxy = pendingDeleteProxy {
                Text(L10n.f("将对以下反向代理进行 删除 操作，是否继续？\n\n%@", proxy.displayName))
            }
        }
    }

    private var list: some View {
        List {
            ForEach(proxies) { p in
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        // 首行：匹配规则 + 前端请求路径（如 "^~ /"，无匹配规则时仅路径）
                        Text(p.displayModifierMatch)
                            .font(.dataMonospacedBody.bold())
                            .lineLimit(1)
                        // 次行：后端地址
                        Text(p.displayProxyPass)
                            .font(.caption.monospaced())
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    // 状态徽标在两行高度上垂直居中
                    if p.enable == true {
                        StatusBadge(text: L10n.t("已启用"), color: .statusRunning)
                    } else {
                        StatusBadge(text: L10n.t("已停用"), color: .statusStopped)
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    actionProxy = p
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDeleteProxy = p
                    } label: {
                        Label(L10n.t("删除"), systemImage: "trash")
                    }
                }
            }
        }
        .refreshable {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            proxies = try await vm.loadProxies(websiteId: websiteId)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func deleteProxy(_ p: WebsiteProxy) async {
        let req = WebsiteProxyUpdateRequest(
            id: websiteId,
            operate: WebsiteProxyOperate.delete.rawValue,
            enable: p.enable ?? true,
            name: p.name ?? "",
            modifier: p.modifier ?? "",
            match: p.match ?? "",
            proxyPass: p.proxyPass ?? "",
            proxyHost: p.proxyHost ?? "$host",
            content: p.content ?? "",
            filePath: p.filePath ?? "",
            sni: p.sni ?? false,
            proxySSLName: p.proxySSLName ?? "$proxy_host",
            sslVerify: p.sslVerify ?? false,
            proxyProtocol: "http://",
            proxyAddress: p.proxyPass ?? ""
        )
        let ok = await vm.operateProxy(websiteId: websiteId, operate: .delete, req: req)
        if ok {
            await load()
        }
    }

    private func toggleProxy(_ p: WebsiteProxy) async {
        togglingProxyId = p.id
        defer { togglingProxyId = nil }
        actionProxy = nil
        let newEnable = !(p.enable ?? true)
        let ok = await vm.toggleProxy(websiteId: websiteId, proxy: p, enable: newEnable)
        if ok {
            await load()
        }
    }
}

/// 反向代理创建/编辑
struct WebsiteProxyEditView: View {
    let websiteId: Int
    let proxy: WebsiteProxy?
    @ObservedObject var vm: WebsitesViewModel
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var match = "/"
    @State private var modifier = ""
    @State private var proxyProtocol = "http://"
    @State private var proxyAddress = ""
    @State private var proxyHost = "$host"
    @State private var enable = true
    // SNI（仅 HTTPS 后端）
    @State private var sni = false
    @State private var proxySSLName = "$proxy_host"
    @State private var sslVerify = false
    @State private var isSaving = false

    private var isEdit: Bool { proxy != nil }

    /// 匹配规则选项（对应 nginx location 修饰符）
    private let modifierOptions: [(value: String, label: String)] = [
        ("",    L10n.t("无（前缀匹配）")),
        ("=",   L10n.t("= 精确匹配")),
        ("^~",  L10n.t("^~ 匹配路径开头")),
        ("~",   L10n.t("~ 正则匹配（区分大小写）")),
        ("~*",  L10n.t("~* 正则匹配（不区分大小写）")),
    ]

    var body: some View {
        Form {
            Section {
                FormTextField(label: L10n.t("名称"), text: $name,
                              disabled: isEdit)
                Picker(L10n.t("匹配规则"), selection: $modifier) {
                    ForEach(modifierOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                FormTextField(label: L10n.t("前端请求路径"), prompt: "/api",
                              text: $match)
            } header: {
                Text(L10n.t("路由"))
            } footer: {
                Text(L10n.t("匹配规则对应 nginx location 修饰符：= 精确匹配，~ 正则匹配，^~ 匹配路径开头等"))
            }

            Section {
                Picker(L10n.t("协议"), selection: $proxyProtocol) {
                    Text("http://").tag("http://")
                    Text("https://").tag("https://")
                }
                FormTextField(label: L10n.t("后端代理地址"), prompt: "host:port",
                              text: $proxyAddress, style: .stacked, keyboardType: .URL)
                FormTextField(label: L10n.t("后端域名"), text: $proxyHost)
            } header: {
                Text(L10n.t("后端代理"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !proxyAddress.isEmpty {
                        Text(L10n.f("完整地址：%@%@", proxyProtocol, proxyAddress))
                            .font(.caption.monospaced())
                            .foregroundStyle(.blue)
                    }
                    Text(L10n.t("后端域名回填 proxy_set_header Host，默认 $host 表示沿用客户端请求的主机名"))
                }
            }

            if proxyProtocol == "https://" {
                Section {
                    Toggle(L10n.t("回源 SNI"), isOn: $sni)
                    if sni {
                        FormTextField(label: L10n.t("代理 SNI 名称"), text: $proxySSLName)
                    }
                    Toggle(L10n.t("校验后端 SSL 证书"), isOn: $sslVerify)
                } header: {
                    Text(L10n.t("SNI 设置"))
                } footer: {
                    Text(L10n.t("HTTPS 后端启用回源 SNI 后将在握手时携带 SNI（proxy_ssl_server_name on），代理 SNI 名称默认 $proxy_host"))
                }
            }

            Section(L10n.t("状态")) {
                Toggle(L10n.t("启用"), isOn: $enable)
            }
        }
        .navigationTitle(isEdit ? L10n.t("编辑代理") : L10n.t("创建代理"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEdit ? L10n.t("保存") : L10n.t("创建")) {
                    Task { await save() }
                }
                .disabled(!canSubmit || isSaving)
            }
        }
        .onAppear(perform: fillFromProxy)
    }

    private var canSubmit: Bool {
        !name.isEmpty && !match.isEmpty && !proxyAddress.isEmpty
    }

    private func fillFromProxy() {
        guard let p = proxy else { return }
        name = p.name ?? ""
        match = p.match ?? "/"
        modifier = p.modifier ?? ""
        enable = p.enable ?? true
        proxyHost = p.proxyHost ?? "$host"
        sni = p.sni ?? false
        proxySSLName = (p.proxySSLName?.isEmpty == false) ? p.proxySSLName! : "$proxy_host"
        sslVerify = p.sslVerify ?? false
        let pass = p.proxyPass ?? ""
        if pass.hasPrefix("https://") {
            proxyProtocol = "https://"
            proxyAddress = String(pass.dropFirst("https://".count))
        } else if pass.hasPrefix("http://") {
            proxyProtocol = "http://"
            proxyAddress = String(pass.dropFirst("http://".count))
        } else {
            proxyAddress = pass
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let operate: WebsiteProxyOperate = isEdit ? .edit : .create
        let req = WebsiteProxyUpdateRequest(
            id: websiteId,
            operate: operate.rawValue,
            enable: enable,
            name: name,
            modifier: modifier,
            match: match,
            proxyPass: "\(proxyProtocol)\(proxyAddress)",
            proxyHost: proxyHost.isEmpty ? "$host" : proxyHost,
            sni: sni,
            proxySSLName: proxySSLName.isEmpty ? "$proxy_host" : proxySSLName,
            sslVerify: sslVerify,
            proxyProtocol: proxyProtocol,
            proxyAddress: proxyAddress
        )
        let ok = await vm.operateProxy(websiteId: websiteId, operate: operate, req: req)
        if ok {
            onDone()
            dismiss()
        }
    }
}

/// 反向代理源文（修改 nginx 配置片段）
struct WebsiteProxySourceView: View {
    let websiteId: Int
    let proxy: WebsiteProxy
    @ObservedObject var vm: WebsitesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var content = ""
    @State private var originalContent = ""
    @State private var isSaving = false

    private var hasChanges: Bool { content != originalContent }

    var body: some View {
        TextEditor(text: $content)
            .font(.panelScaled(12, design: .monospaced))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 4)
            .background(Color(.secondarySystemBackground))
        .navigationTitle(L10n.f("源文：%@", proxy.displayName))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text(L10n.t("保存")).bold()
                    }
                }
                .disabled(isSaving || !hasChanges)
            }
        }
        .onAppear {
            if content.isEmpty {
                content = proxy.content ?? ""
                originalContent = content
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await vm.saveProxyFile(
            websiteId: websiteId,
            name: proxy.name ?? "",
            content: content
        )
        if ok {
            originalContent = content
            dismiss()
        }
    }
}

