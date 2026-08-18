//
//  WebsiteDetailView.swift
//  1PanelClient
//

import SwiftUI

// MARK: - 网站详情

struct WebsiteDetailView: View {
    let website: Website
    @ObservedObject var vm: WebsitesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var detail: WebsiteFull?
    @State private var isLoadingDetail = false
    @State private var showDeleteSheet = false
    @State private var showEdit = false
    @State private var isOperating = false
    @State private var pendingToggle: Bool?
    @State private var isStatusExpanded = false
    @State private var showBackup = false
    // 三点菜单 / 抽屉导航目标
    @State private var showProxies = false
    @State private var showNginx = false
    @State private var showDefaultDoc = false
    @State private var showLimitConn = false
    @State private var showRedirects = false
    @State private var showAuths = false
    @State private var showMenu = false

    /// 当前服务器配置（根目录跳转文件管理用）
    private var server: ServerConfig {
        ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
    }

    var body: some View {
        List {
            if isLoadingDetail && detail == nil {
                Section { HStack { ProgressView(); Text("加载中…") } }
            } else if let d = detail {
                // 状态与操作（下拉抽屉，与容器详情一致）
                Section {
                    drawerHeaderRow

                    if isStatusExpanded {
                        operationsRow
                            .padding(.top, 4)
                            .padding(.bottom, 2)
                    }
                }

                // 基本信息
                Section {
                    if let alias = d.alias, !alias.isEmpty {
                        InfoRow("别名", value: alias)
                    }
                    if let domain = d.primaryDomain, !domain.isEmpty {
                        InfoRow("主域名", value: domain)
                    }
                    InfoRow("类型", value: Website.typeDisplayName(for: d.type ?? website.type))
                    if let p = d.sitePath, !p.isEmpty {
                        NavigationLink {
                            FilesView(server: server, initialPath: p)
                        } label: {
                            InfoRow("根目录", value: p)
                        }
                        .buttonStyle(.plain)
                    }
                    if let created = d.createdAt, !created.isEmpty {
                        InfoRow("创建时间", value: String(created.prefix(19)))
                    }
                } header: {
                    SectionLabel(title: "基本信息", systemImage: "doc.text")
                }

                // 操作入口（HTTPS / 日志）
                Section {
                    NavigationLink {
                        WebsiteHTTPSView(websiteId: website.id, vm: vm)
                    } label: {
                        HStack {
                            HTTPSLinkIcon()
                            Text("HTTPS")
                                .foregroundStyle(.primary)
                            Spacer()
                            if d.webSiteSSLId ?? 0 > 0 {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    NavigationLink {
                        WebsiteLogPage(websiteId: website.id, vm: vm)
                    } label: {
                        Label("日志", systemImage: "doc.text.magnifyingglass")
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Section {
                    InfoRow("主域名", value: website.primaryDomain ?? "—")
                    InfoRow("类型", value: website.typeDisplayName)
                }
            }
        }
        .navigationTitle(website.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // 右上角三点菜单：反代 / 默认文档 / 流量限制 / 重定向 / 密码访问 / 其他
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EllipsisMenuButton {
                    withAnimation(.easeOut(duration: 0.18)) { showMenu.toggle() }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showMenu {
                EllipsisMenuPopup(entries: [
                    .action(title: "基础信息") { showEdit = true },
                    .action(title: "反向代理") { showProxies = true },
                    .action(title: "默认文档") { showDefaultDoc = true },
                    .action(title: "流量限制") { showLimitConn = true },
                    .action(title: "重定向") { showRedirects = true },
                    .action(title: "密码访问") { showAuths = true },
                ]) {
                    withAnimation(.easeIn(duration: 0.12)) { showMenu = false }
                }
            }
        }
        // 右下角悬浮：浏览器打开网站链接（protocol + primaryDomain）
        .overlay(alignment: .bottomTrailing) {
            if let url = website.browserURL {
                WebsiteLinkFab(url: url)
            }
        }
        .navigationDestination(isPresented: $showBackup) {
            BackupListView(target: websiteBackupTarget)
        }
        .navigationDestination(isPresented: $showProxies) {
            WebsiteProxiesView(websiteId: website.id, vm: vm)
        }
        .navigationDestination(isPresented: $showNginx) {
            WebsiteNginxView(websiteId: website.id, vm: vm)
        }
        .navigationDestination(isPresented: $showDefaultDoc) {
            WebsiteDefaultDocView(websiteId: website.id, vm: vm)
        }
        .navigationDestination(isPresented: $showLimitConn) {
            WebsiteLimitConnView(websiteId: website.id, vm: vm)
        }
        .navigationDestination(isPresented: $showRedirects) {
            WebsiteRedirectView(websiteId: website.id, vm: vm)
        }
        .navigationDestination(isPresented: $showAuths) {
            WebsiteAuthsView(websiteId: website.id, vm: vm)
        }
        .navigationDestination(isPresented: $showEdit) {
            if let d = detail {
                WebsiteEditView(detail: d, vm: vm) {
                    Task {
                        await loadDetail()
                        await vm.refresh()
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await loadDetail()
        }
        .onReceive(vm.$deletedWebsiteId) { deletedId in
            if let deletedId = deletedId, deletedId == website.id {
                dismiss()
            }
        }
        .sheet(isPresented: $showDeleteSheet) {
            WebsiteDeleteSheet(website: website, vm: vm)
        }
        .alert(
            (pendingToggle == true) ? "启用" : "停止",
            isPresented: Binding(
                get: { pendingToggle != nil },
                set: { if !$0 { pendingToggle = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingToggle = nil }
            Button("确认", role: .destructive) {
                let target = pendingToggle
                pendingToggle = nil
                guard let target else { return }
                Task { await toggleStatus(current: detail?.status, to: target) }
            }
        } message: {
            Text("将对网站「\(website.displayName)」进行 \(pendingToggle == true ? "启用" : "停止") 操作，是否继续？")
        }
    }

    private func loadDetail() async {
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        detail = await vm.loadDetail(id: website.id)
    }

    // MARK: - 可折叠状态面板（与容器详情一致的下拉抽屉）

    private var isRunning: Bool {
        (detail?.status ?? "").lowercased() == "running"
    }

    private var drawerHeaderRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(website.displayName)
                    .font(.body.bold())
                    .lineLimit(1)
                Text(Website.typeDisplayName(for: detail?.type ?? website.type))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                StatusDot(color: detail?.statusColor ?? .secondary)
                Text(detail?.status ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isStatusExpanded.toggle()
                }
            } label: {
                Image(systemName: isStatusExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(isOperating)
        }
        .padding(.vertical, 2)
    }

    private var operationsRow: some View {
        HStack(spacing: 8) {
            actionButton(
                title: isRunning ? "停止" : "启用",
                icon: isRunning ? "stop.fill" : "play.fill",
                color: isRunning ? .orange : .green,
                busy: isOperating
            ) {
                pendingToggle = !isRunning
            }
            actionButton(
                title: "备份",
                icon: "externaldrive.badge.timemachine",
                color: .blue
            ) {
                showBackup = true
            }
            actionButton(
                title: "编辑",
                icon: "doc.text",
                color: .cyan
            ) {
                showNginx = true
            }
            actionButton(
                title: "删除",
                icon: "trash",
                color: .red
            ) {
                showDeleteSheet = true
            }
        }
    }

    @ViewBuilder
    private func actionButton(
        title: String,
        icon: String,
        color: Color,
        busy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if busy {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(color)
                        .frame(width: 22, height: 22)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(isOperating)
    }

    /// 网站备份目标（type=website；后端按 website.alias 查库，备份记录也以 alias 存
    /// 储，与网页端一致优先传 alias，主域名仅作兜底）
    private var websiteBackupTarget: BackupTarget {
        let alias = detail?.alias ?? website.alias ?? website.primaryDomain ?? website.displayName
        return BackupTarget(type: "website", name: alias, detailName: alias)
    }

    private func toggleStatus(current: String?, to running: Bool) async {
        isOperating = true
        let op = running ? "start" : "stop"
        let ok = await vm.operateWebsite(id: website.id, operate: op)
        if ok {
            try? await Task.sleep(for: .seconds(1))
            await loadDetail()
        }
        isOperating = false
    }
}


// MARK: - 编辑网站基础信息（主域名 / 备注）

/// 编辑网站基础信息：POST /websites/update 仅接收主域名/备注等少量字段，
/// 其余字段（IPV6/expireDate/favorite/分组）按当前详情原样回填，避免被零值覆盖。
struct WebsiteEditView: View {
    let detail: WebsiteFull
    @ObservedObject var vm: WebsitesViewModel
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var primaryDomain: String
    @State private var remark: String
    @State private var isSaving = false

    init(detail: WebsiteFull, vm: WebsitesViewModel, onSaved: @escaping () -> Void) {
        self.detail = detail
        self.vm = vm
        self.onSaved = onSaved
        _primaryDomain = State(initialValue: detail.primaryDomain ?? "")
        _remark = State(initialValue: detail.remark ?? "")
    }

    private var trimmedDomain: String {
        primaryDomain.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section {
                TextField("example.com", text: $primaryDomain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } header: {
                Text("主域名")
            } footer: {
                Text("网站的主访问域名，修改后请确保域名解析已指向本服务器")
            }

            Section {
                TextField("备注（可选）", text: $remark)
            } header: {
                Text("备注")
            }
        }
        .navigationTitle("编辑网站")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "保存中…" : "保存") {
                    Task {
                        isSaving = true
                        var req = WebsiteUpdateRequest(from: detail)
                        req.primaryDomain = trimmedDomain
                        req.remark = remark
                        if await vm.updateWebsite(req) {
                            onSaved()
                            dismiss()
                        }
                        isSaving = false
                    }
                }
                .disabled(trimmedDomain.isEmpty || isSaving)
            }
        }
    }
}

// MARK: - 删除网站表单

struct WebsiteDeleteSheet: View {
    let website: Website
    @ObservedObject var vm: WebsitesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var forceDelete = false
    @State private var deleteBackup = false
    @State private var deleteApp = false
    @State private var deleteDB = false
    @State private var isDeleting = false

    /// 是否为一键部署（关联应用）
    private var isDeployment: Bool {
        (website.type ?? "").lowercased() == "deployment"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("确定要删除 \(website.displayName) 吗？")
                            .bold()
                    }
                } footer: {
                    Text("删除操作不可撤销，请谨慎操作")
                }

                Section("删除选项") {
                    Toggle("强制删除", isOn: $forceDelete)
                    Toggle("删除备份", isOn: $deleteBackup)
                    if isDeployment {
                        Toggle("删除关联应用", isOn: $deleteApp)
                    }
                    Toggle("删除数据库", isOn: $deleteDB)
                }
            }
            .navigationTitle("删除网站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("删除", role: .destructive) {
                        Task { await performDelete() }
                    }
                    .disabled(isDeleting)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func performDelete() async {
        isDeleting = true
        await vm.deleteWebsite(
            id: website.id,
            deleteApp: deleteApp,
            deleteBackup: deleteBackup,
            forceDelete: forceDelete,
            deleteDB: deleteDB
        )
        dismiss()
    }
}

