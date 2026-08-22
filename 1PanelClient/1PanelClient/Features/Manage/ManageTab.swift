//
//  ManageTab.swift
//  1PanelClient
//
//  管理：分组列表聚合各功能入口，支持隐藏未使用模块
//  对齐 1Panel 官方 App 的「管理」Tab 结构
//

import SwiftUI
import Combine

struct ManageTab: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var prefs = ManagePrefs()
    @State private var navPath = NavigationPath()
    @State private var showEditSheet = false
    @State private var showRemoveServer = false

    /// 跨 Tab 跳转入口：外部（如 OverviewTab）设置此值时，自动 push 到对应页面
    @Binding var initialItem: ManageItem?
    /// 向 MainTabView 同步导航深度：true=根列表，false=子页面（隐藏 Tab 栏）
    @Binding var atRoot: Bool

    init(manager: ServerManager, initialItem: Binding<ManageItem?> = .constant(nil), atRoot: Binding<Bool> = .constant(true)) {
        self.manager = manager
        self._initialItem = initialItem
        self._atRoot = atRoot
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            List {
                ForEach(Array(ManageItem.groups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group.items) { item in
                            if prefs.isEnabled(item) {
                                manageRow(item)
                            }
                        }
                    } header: {
                        if !group.title.isEmpty {
                            Text(group.title)
                        }
                    }
                }

                // 移除当前服务器（独立分组，与「编辑」区分开）
                Section {
                    Button {
                        showRemoveServer = true
                    } label: {
                        HStack {
                            Spacer()
                            Text(L10n.t("移除服务器"))
                                .foregroundStyle(.red)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.current == nil)
                }

                Section {
                    Button {
                        showEditSheet = true
                    } label: {
                        HStack {
                            Spacer()
                            Text(L10n.t("编辑"))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            // 内容超屏后为底部自定义 Tab 栏留出滚动空间（与首页/设置页的处理一致）
            .contentMargins(.bottom, 60, for: .scrollContent)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ManageItem.self) { item in
                destination(for: item)
            }
            .sheet(isPresented: $showEditSheet) {
                ManageEditView(prefs: prefs)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            // 移除当前服务器前确认（会连带清除 Keychain 中的 API 密钥）—— 居中 alert
            .alert(L10n.t("移除服务器"), isPresented: $showRemoveServer) {
                Button(L10n.t("取消"), role: .cancel) {}
                Button(L10n.t("移除"), role: .destructive) {
                    if let server = manager.current {
                        manager.remove(server)
                    }
                }
            } message: {
                Text(L10n.f("将移除「%@」的连接配置与已保存的 API 密钥，此操作不可恢复。", manager.current?.name ?? ""))
            }
        }
        .onChange(of: initialItem) { _, newItem in
            guard let newItem else { return }
            if newItem.available {
                pushIfNeeded(newItem)
            }
            initialItem = nil
        }
        .onChange(of: navPath.count) { _, count in
            atRoot = count == 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .popAppDetail)) { _ in
            popToAppList()
        }
        .environmentObject(prefs)
    }

    /// 跨 Tab 跳转：重置为单元素栈再进入目标页——
    /// 避免从首页反复点击叠出 [monitor, monitor]（NavigationPath 无法读取栈内元素，无法按值去重）
    private func pushIfNeeded(_ item: ManageItem) {
        navPath = NavigationPath([item])
    }

    /// pop 回应用列表：重置为 [.apps]。
    /// 不依赖「弹几层」的假设——兼容 isPresented 推入是否计入 NavigationPath 的系统行为差异；
    /// 应用列表会重建并重新加载（卸载/升级后正好需要刷新）
    private func popToAppList() {
        navPath = NavigationPath([ManageItem.apps])
    }

    @ViewBuilder
    private func manageRow(_ item: ManageItem) -> some View {
        NavigationLink(value: item) {
            HStack(spacing: 14) {
                IconBadge(systemName: item.icon, color: item.color)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .foregroundStyle(item.available ? .primary : .secondary)
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !item.available {
                    StatusBadge(text: L10n.t("敬请期待"), color: .secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .disabled(!item.available)
    }

    /// push 目标（由外层 NavigationStack 提供导航栏与返回按钮）
    @ViewBuilder
    private func destination(for item: ManageItem) -> some View {
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        switch item {
        case .apps:
            AppsTab(manager: manager)
        case .websites:
            WebsitesTab(manager: manager)
        case .containers:
            ContainersTab(manager: manager)
        case .cronjob:
            CronjobsTab(manager: manager)
        case .firewall:
            FirewallView(server: server)
        case .database:
            DatabasesView(server: server)
        case .terminal:
            TerminalHostsView(server: server, localTitle: manager.current?.name)
        case .process:
            ProcessView(server: server)
        case .sshService:
            SSHView(server: server)
        case .fail2ban:
            Fail2banView(server: server)
        case .waf:
            WAFView(server: server)
        case .nodeManage:
            NodeManageView(manager: manager, server: server, navPath: $navPath)
        case .backupAccount:
            BackupAccountsView(server: server)
        case .taskCenter:
            TaskCenterView(server: server)
        case .alert:
            AlertNotificationView(server: server)
        case .logs:
            LogsView(server: server)
        case .monitor:
            MonitorView(server: server)
        case .files:
            FilesView(server: server)
        case .websiteMonitor:
            WebsiteMonitorView(server: server)
        case .wafMonitor:
            WAFMonitorView(server: server)
        }
    }
}

// MARK: - 编辑（显示/隐藏）视图

struct ManageEditView: View {
    @ObservedObject var prefs: ManagePrefs
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L10n.t("隐藏的功能将从管理列表中移除，但不会影响服务器上的实际运行。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(ManageItem.groups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group.items) { item in
                            HStack(spacing: 12) {
                                IconBadge(systemName: item.icon, color: item.color, size: 34, cornerRadius: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                    Text(item.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { prefs.isEnabled(item) },
                                    set: { prefs.setEnabled($0, for: item) }
                                ))
                                .labelsHidden()
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        if !group.title.isEmpty {
                            Text(group.title)
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("自定义功能"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("完成")) { dismiss() }
                }
            }
        }
        // sheet 里 environmentObject 会重新注入，避免与 sheet 内部新建冲突
        .environmentObject(prefs)
    }
}

// MARK: - 持久化偏好

/// 管理模块的显示/隐藏偏好，持久化到 UserDefaults
final class ManagePrefs: ObservableObject {
    @Published private(set) var disabledItems: Set<String>

    private let key = "manage.disabledItems"

    init() {
        if let raw = UserDefaults.standard.array(forKey: key) as? [String] {
            disabledItems = Set(raw)
        } else {
            disabledItems = []
        }
    }

    func isEnabled(_ item: ManageItem) -> Bool {
        !disabledItems.contains(item.rawValue)
    }

    func setEnabled(_ enabled: Bool, for item: ManageItem) {
        if enabled {
            disabledItems.remove(item.rawValue)
        } else {
            disabledItems.insert(item.rawValue)
        }
        UserDefaults.standard.set(Array(disabledItems), forKey: key)
    }
}

// MARK: - 管理项定义

/// 管理功能项（顶层枚举，供 ManageTab / ManageEditView / ManagePrefs 共用）
enum ManageItem: String, Identifiable {
    case apps
    case websites
    case database
    case containers
    case terminal
    case files
    case monitor
    case process
    case sshService
    case firewall
    case fail2ban
    case waf
    case alert
    case nodeManage
    case backupAccount
    case cronjob
    case taskCenter
    case logs
    case websiteMonitor
    case wafMonitor

    var id: String { rawValue }

    /// 管理页分组（带标题），ManageTab 与「自定义功能」编辑页共用
    static let groups: [(title: String, items: [ManageItem])] = [
        (L10n.t("应用"), [.apps, .websites, .database, .containers]),
        (L10n.t("主机"), [.terminal, .files, .monitor, .process, .sshService]),
        (L10n.t("安全"), [.firewall, .fail2ban, .waf]),
        (L10n.t("高级功能"), [.websiteMonitor, .nodeManage, .wafMonitor]),
        (L10n.t("面板"), [.alert, .backupAccount, .cronjob, .taskCenter, .logs]),
    ]

    var title: String {
        switch self {
        case .apps:        return L10n.t("应用程序")
        case .websites:    return L10n.t("网站")
        case .database:    return L10n.t("数据库")
        case .containers:  return L10n.t("容器")
        case .terminal:    return L10n.t("终端")
        case .files:       return L10n.t("文件")
        case .monitor:     return L10n.t("监控")
        case .process:     return L10n.t("进程")
        case .sshService:  return L10n.t("SSH 服务管理")
        case .firewall:    return L10n.t("防火墙")
        case .fail2ban:    return "Fail2ban"
        case .waf:         return "WAF"
        case .alert:       return L10n.t("告警通知")
        case .nodeManage:  return L10n.t("多机管理")
        case .backupAccount: return L10n.t("备份账号")
        case .cronjob:     return L10n.t("计划任务")
        case .taskCenter:  return L10n.t("任务中心")
        case .logs:        return L10n.t("日志")
        case .websiteMonitor: return L10n.t("网站监控")
        case .wafMonitor:  return L10n.t("WAF 监控")
        }
    }

    var subtitle: String {
        switch self {
        case .apps:        return L10n.t("已安装应用 / 应用商店")
        case .websites:    return L10n.t("网站 / SSL 证书")
        case .database:    return L10n.t("管理数据库实例")
        case .containers:  return L10n.t("Docker 容器")
        case .terminal:    return L10n.t("本机终端 / SSH 连接主机")
        case .files:       return L10n.t("服务器文件管理")
        case .monitor:     return L10n.t("负载 / CPU / 内存 / I/O / 网络")
        case .process:     return L10n.t("系统进程监控")
        case .sshService:  return L10n.t("面板主机 SSH 服务与配置")
        case .firewall:    return L10n.t("防火墙规则")
        case .fail2ban:    return L10n.t("SSH 防暴力破解")
        case .waf:         return L10n.t("Web 应用防火墙")
        case .alert:       return L10n.t("告警规则 / 日志 / 发送方式")
        case .nodeManage:  return L10n.t("节点概览 / 添加节点 / 切换（专业版）")
        case .backupAccount: return L10n.t("MINIO / WebDAV / SFTP 备份存储")
        case .cronjob:     return L10n.t("定时备份与脚本")
        case .taskCenter:  return L10n.t("应用同步 / 镜像拉取等异步任务")
        case .logs:        return L10n.t("面板 / SSH / 网站日志")
        case .websiteMonitor: return L10n.t("QPS / 访客趋势 / 访客地图 / 请求日志")
        case .wafMonitor:  return L10n.t("拦截趋势 / 拦截记录 / 封锁记录")
        }
    }

    var icon: String {
        switch self {
        case .apps:        return "app.badge"
        case .websites:    return "globe"
        case .database:    return "cylinder"
        case .containers:  return "shippingbox"
        case .terminal:    return "terminal"
        case .files:       return "folder.fill"
        case .monitor:     return "chart.line.uptrend.xyaxis"
        case .process:     return "chart.bar"
        case .sshService:  return "terminal"
        case .firewall:    return "flame"
        case .fail2ban:    return "shield.lefthalf.filled"
        case .waf:         return "flame.fill"
        case .alert:       return "bell.badge.fill"
        case .nodeManage:  return "server.rack"
        case .backupAccount: return "externaldrive.badge.icloud"
        case .cronjob:     return "clock.badge.checkmark"
        case .taskCenter:  return "checklist"
        case .logs:        return "doc.text.magnifyingglass"
        case .websiteMonitor: return "chart.pie.fill"
        case .wafMonitor:  return "chart.bar.xaxis"
        }
    }

    var color: Color {
        switch self {
        case .apps:        return .blue
        case .websites:    return .green
        case .database:    return .purple
        case .containers:  return .indigo
        case .terminal:    return .primary  // 深色模式下 .black 图标不可见，改用自适应色
        case .files:       return .yellow
        case .monitor:     return .mint
        case .process:     return .pink
        case .sshService:  return .blue
        case .firewall:    return .orange
        case .fail2ban:    return .indigo
        case .waf:         return .red
        case .alert:       return .orange
        case .nodeManage:  return .teal
        case .backupAccount: return .blue
        case .cronjob:     return .teal
        case .taskCenter:  return .brown
        case .logs:        return .cyan
        case .websiteMonitor: return .indigo
        case .wafMonitor:  return .red
        }
    }

    var available: Bool { true }
}
