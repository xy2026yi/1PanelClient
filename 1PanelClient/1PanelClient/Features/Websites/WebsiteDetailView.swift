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
    // 新增功能入口（依据 logs/网站修改与增加-1.md）
    @State private var showDomains = false
    @State private var showLbs = false
    @State private var showCors = false
    @State private var showRealIP = false
    @State private var showRewrite = false
    @State private var showLeech = false
    @State private var showOther = false
    // PHP / 资源入口（三点菜单子页，位于重定向与其他之间）
    @State private var showPHP = false
    @State private var showResource = false
    /// 浏览器打开网站链接（toolbar 打开按钮用）
    @Environment(\.openURL) private var openURL

    /// 当前服务器配置（根目录跳转文件管理用）
    private var server: ServerConfig {
        ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
    }

    var body: some View {
        List {
            if isLoadingDetail && detail == nil {
                Section { LoadingStateView(compact: true) }
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
                    if let domain = d.primaryDomain, !domain.isEmpty {
                        InfoRow(L10n.t("主域名"), value: domain)
                    }
                    // 其他域名：详情 domains 数组去掉主域名后的部分，按行展示
                    let otherDomainList = (d.domains ?? [])
                        .compactMap(\.domain)
                        .filter { !$0.isEmpty && $0 != d.primaryDomain }
                    if !otherDomainList.isEmpty {
                        InfoRow(L10n.t("其他域名"), value: otherDomainList.joined(separator: "\n"))
                    }
                    InfoRow(L10n.t("类型"), value: Website.typeDisplayName(for: d.type ?? website.type))
                    if let p = d.sitePath, !p.isEmpty {
                        NavigationLink {
                            FilesView(server: server, initialPath: p)
                        } label: {
                            InfoRow(L10n.t("根目录"), value: p)
                        }
                        .buttonStyle(.plain)
                    }
                    if let created = d.createdAt, !created.isEmpty {
                        InfoRow(L10n.t("创建时间"), value: String(created.prefix(19)))
                    }
                } header: {
                    SectionLabel(title: L10n.t("基本信息"), systemImage: "doc.text")
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
                        WebsiteLogPage(website: website, vm: vm)
                    } label: {
                        Label(L10n.t("日志"), systemImage: "doc.text.magnifyingglass")
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            } else if let err = vm.detailErrorMessage {
                // 详情加载失败：错误态 + 重试（此前失败后仅回落两行基本信息，
                // 无恢复入口，与全站详情页惯例不符）
                LoadErrorStateView(message: err) {
                    Task { await loadDetail() }
                }
            } else {
                Section {
                    InfoRow(L10n.t("主域名"), value: website.primaryDomain ?? "—")
                    InfoRow(L10n.t("类型"), value: website.typeDisplayName)
                }
            }
        }
        .navigationTitle(website.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toastOverlay(message: $vm.toastMessage)
        .overlay(alignment: .topTrailing) {
            if showMenu {
                EllipsisMenuPopup(entries: [
                    .action(title: L10n.t("域名设置")) { showDomains = true },
                    .action(title: L10n.t("默认文档")) { showDefaultDoc = true },
                    .action(title: L10n.t("流量限制")) { showLimitConn = true },
                    .action(title: L10n.t("反向代理")) { showProxies = true },
                    .action(title: L10n.t("负载均衡")) { showLbs = true },
                    .action(title: L10n.t("密码访问")) { showAuths = true },
                    .action(title: L10n.t("跨域访问")) { showCors = true },
                    .action(title: L10n.t("真实IP")) { showRealIP = true },
                    .action(title: L10n.t("伪静态")) { showRewrite = true },
                    .action(title: L10n.t("防盗链")) { showLeech = true },
                    .action(title: L10n.t("重定向")) { showRedirects = true },
                    .action(title: L10n.t("PHP")) { showPHP = true },
                    .action(title: L10n.t("资源")) { showResource = true },
                    .action(title: L10n.t("其他")) { showOther = true },
                ]) {
                    withAnimation(Motion.fast) { showMenu = false }
                }
            }
        }
        // 右上角：浏览器打开网站链接 + 三点菜单（反代 / 默认文档 / 流量限制 / 重定向 / 密码访问 / 其他）
        .toolbar {
            if let url = website.browserURL {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .accessibilityLabel(L10n.t("在浏览器打开网站"))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                EllipsisMenuButton {
                    withAnimation(Motion.fast) { showMenu.toggle() }
                }
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
        .navigationDestination(isPresented: $showPHP) {
            WebsitePHPView(website: website, vm: vm) {
                Task { await loadDetail() }
            }
        }
        .navigationDestination(isPresented: $showResource) {
            WebsiteResourceView(website: website, vm: vm) {
                Task { await loadDetail() }
            }
        }
        // 新增功能入口（依据 logs/网站修改与增加-1.md）
        .navigationDestination(isPresented: $showDomains) {
            WebsiteDomainsView(websiteId: website.id, vm: vm)
        }
        .navigationDestination(isPresented: $showLbs) {
            WebsiteLbsView(websiteId: website.id, vm: vm)
        }
        .navigationDestination(isPresented: $showCors) {
            WebsiteCorsView(websiteId: website.id, vm: vm)
        }
        .navigationDestination(isPresented: $showRealIP) {
            WebsiteRealIPView(websiteId: website.id, vm: vm)
        }
        .navigationDestination(isPresented: $showRewrite) {
            WebsiteRewriteView(websiteId: website.id, vm: vm)
        }
        .navigationDestination(isPresented: $showLeech) {
            WebsiteLeechView(websiteId: website.id, vm: vm)
        }
        .navigationDestination(isPresented: $showOther) {
            WebsiteOtherView(website: website, vm: vm)
        }
        .navigationDestination(isPresented: $showAuths) {
            WebsiteAuthsView(websiteId: website.id, vm: vm)
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
            WebsiteDeleteConfirmSheet(website: website, vm: vm)
        }
        .alert(
            (pendingToggle == true) ? L10n.t("启用") : L10n.t("停止"),
            isPresented: Binding(
                get: { pendingToggle != nil },
                set: { if !$0 { pendingToggle = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingToggle = nil }
            Button(L10n.t("确认"), role: .destructive) {
                Haptic.warning()
                let target = pendingToggle
                pendingToggle = nil
                guard let target else { return }
                Task { await toggleStatus(current: detail?.status, to: target) }
            }
        } message: {
            Text(L10n.f("将对网站「%@」进行 %@ 操作，是否继续？", website.displayName, pendingToggle == true ? L10n.t("启用") : L10n.t("停止")))
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
                withAnimation(Motion.standard) {
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
                title: isRunning ? L10n.t("停止") : L10n.t("启用"),
                icon: isRunning ? "stop.fill" : "play.fill",
                color: isRunning ? .orange : .green,
                busy: isOperating
            ) {
                pendingToggle = !isRunning
            }
            actionButton(
                title: L10n.t("备份"),
                icon: "externaldrive.badge.timemachine",
                color: .blue
            ) {
                showBackup = true
            }
            actionButton(
                title: L10n.t("编辑"),
                icon: "doc.text",
                color: .cyan
            ) {
                showNginx = true
            }
            actionButton(
                title: L10n.t("删除"),
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
        CardActionButton(title: title, icon: icon, color: color, busy: busy, disabled: isOperating, action: action)
    }

    // MARK: - PHP 运行环境 / 防跨站攻击 / 关联数据库

    // 均已移至三点菜单子页（WebsitePHPView / WebsiteResourceView）

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


// MARK: - 删除网站确认（R1 输入域名确认 + 连带删除选项）

/// 包装 TextInputConfirmSheet：连带删除选项作为 options 传入，
/// Toggle 状态由本视图持有，每次呈现自动重置。
struct WebsiteDeleteConfirmSheet: View {
    let website: Website
    @ObservedObject var vm: WebsitesViewModel

    @State private var forceDelete = false
    @State private var deleteBackup = false
    @State private var deleteApp = false
    @State private var deleteDB = false

    /// 是否为一键部署（关联应用）
    private var isDeployment: Bool {
        (website.type ?? "").lowercased() == "deployment"
    }

    var body: some View {
        TextInputConfirmSheet(
            title: L10n.t("删除网站"),
            message: L10n.f("此操作不可恢复，勾选的关联资源将一并删除。请输入网站域名「%@」以确认删除。", website.displayName),
            expectedText: website.displayName,
            fieldLabel: L10n.t("确认域名"),
            fieldPlaceholder: L10n.t("网站域名")
        ) {
            Task { await vm.deleteWebsite(
                id: website.id,
                deleteApp: deleteApp,
                deleteBackup: deleteBackup,
                forceDelete: forceDelete,
                deleteDB: deleteDB
            ) }
        } options: {
            Section(L10n.t("删除选项")) {
                Toggle(L10n.t("强制删除"), isOn: $forceDelete)
                Toggle(L10n.t("删除备份"), isOn: $deleteBackup)
                if isDeployment {
                    Toggle(L10n.t("删除关联应用"), isOn: $deleteApp)
                }
                Toggle(L10n.t("删除数据库"), isOn: $deleteDB)
            }
        }
    }
}

