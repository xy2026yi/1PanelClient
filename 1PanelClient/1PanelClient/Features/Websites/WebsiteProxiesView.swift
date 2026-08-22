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
            .presentationDetents([.height(ActionBottomSheet.height(for: 4))])
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
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(p.displayName)
                            .font(.body.bold())
                        Spacer()
                        if p.enable == true {
                            StatusBadge(text: L10n.t("已启用"), color: .statusRunning)
                        } else {
                            StatusBadge(text: L10n.t("已停用"), color: .statusStopped)
                        }
                    }
                    HStack {
                        Label(p.displayMatch, systemImage: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(p.displayProxyPass)
                            .font(.caption.monospaced())
                            .foregroundStyle(.blue)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    actionProxy = p
                }
                .swipeActions {
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
        proxies = await vm.loadProxies(websiteId: websiteId)
    }

    private func deleteProxy(_ p: WebsiteProxy) async {
        let req = WebsiteProxyUpdateRequest(
            id: websiteId,
            operate: WebsiteProxyOperate.delete.rawValue,
            enable: p.enable ?? true,
            name: p.name ?? "",
            match: p.match ?? "",
            proxyPass: p.proxyPass ?? "",
            content: p.content ?? "",
            filePath: p.filePath ?? "",
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
    @State private var proxyProtocol = "http://"
    @State private var proxyAddress = ""
    @State private var enable = true
    @State private var isSaving = false

    private var isEdit: Bool { proxy != nil }

    var body: some View {
        Form {
            Section(L10n.t("路由")) {
                TextField(L10n.t("名称"), text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(L10n.t("路径 (例如 /api)"), text: $match)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                Picker(L10n.t("协议"), selection: $proxyProtocol) {
                    Text("http://").tag("http://")
                    Text("https://").tag("https://")
                }
                TextField(L10n.t("目标地址 (host:port)"), text: $proxyAddress)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text(L10n.t("代理目标"))
            } footer: {
                if !proxyAddress.isEmpty {
                    Text(L10n.f("完整地址：%@%@", proxyProtocol, proxyAddress))
                        .font(.caption.monospaced())
                        .foregroundStyle(.blue)
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
        enable = p.enable ?? true
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
            match: match,
            proxyPass: "\(proxyProtocol)\(proxyAddress)",
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
            .font(.system(size: 12, design: .monospaced))
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

