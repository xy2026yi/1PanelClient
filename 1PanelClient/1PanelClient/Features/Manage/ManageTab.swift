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
    /// 导航路径由 MainTabView 持有：iPad 窗口缩放跨尺寸类切换时双形态分支互换、
    /// 整棵导航树重建，@State 会随重建清空而跳回管理根页
    @Binding var navPath: NavigationPath
    @State private var showEditSheet = false
    @State private var showRemoveServer = false

    /// 跨 Tab 跳转入口：外部（如 OverviewTab）设置此值时，自动 push 到对应页面
    @Binding var initialItem: ManageItem?

    init(manager: ServerManager,
         navPath: Binding<NavigationPath> = .constant(NavigationPath()),
         initialItem: Binding<ManageItem?> = .constant(nil)) {
        self.manager = manager
        self._navPath = navPath
        self._initialItem = initialItem
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
            // 不加 formWidthLimit：侧栏已占 320pt，内容区本身不宽，
            // 再限宽居中会左右露出大空隙、且与首页宽度不一致
            .navigationDestination(for: ManageItem.self) { item in
                destination(for: item)
            }
            .sheet(isPresented: $showEditSheet) {
                ManageEditView(prefs: prefs)
                    .bottomSheetDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            // 移除当前服务器前确认（会连带清除 Keychain 中的 API 密钥）—— 居中 alert
            .alert(L10n.t("移除服务器"), isPresented: $showRemoveServer) {
                Button(L10n.t("取消"), role: .cancel) {}
                Button(L10n.t("移除"), role: .destructive) {
                    Haptic.warning()
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
        .onReceive(NotificationCenter.default.publisher(for: .popAppDetail)) { _ in
            popToAppList()
        }
        .environmentObject(prefs)
    }

    /// 跨 Tab 跳转：进入目标页——
    /// 避免从首页反复点击叠出 [monitor, monitor]（NavigationPath 无法读取栈内元素，无法按值去重）。
    /// 空栈直接 append：整栈替换在 SwiftUI 内部等效 reset+push，一帧内两次导航
    /// 更新会触发 NavigationRequestObserver「每帧多次更新」警告。非空时整栈替换
    /// 为 [item]：丢掉旧栈是跨 Tab「直达」的预期语义（不保留旧浏览位置），
    /// 与空栈 append 的差别在于空栈场景下替换与 push 同帧、非空场景没有
    /// 「先有内容再 reset」的叠加帧，未观测到该路径触发警告
    private func pushIfNeeded(_ item: ManageItem) {
        if navPath.isEmpty {
            navPath.append(item)
        } else {
            navPath = NavigationPath([item])
        }
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
        destinationBody(item, server: server)
            // 切换服务器时整页重建：页面内 @StateObject VM 在 init 时绑定了服务器快照，
            // 不重建会继续请求旧服务器（导航栈与 Tab 容器在切换时均保活）
            .id(server.id)
    }

    @ViewBuilder
    private func destinationBody(_ item: ManageItem, server: ServerConfig) -> some View {
        switch item {
        case .apps:
            AppsTab(manager: manager)
        case .websites:
            ManageHubView(title: L10n.t("网站"), items: [.websiteList, .certificates])
        case .websiteList:
            WebsitesTab(manager: manager)
        case .certificates:
            CertificatesTab(manager: manager)
        case .containers:
            ContainersTab(manager: manager)
        case .cronjob:
            ManageHubView(title: L10n.t("计划任务"), items: [.cronjobList, .scriptLibrary])
        case .cronjobList:
            CronjobsTab(manager: manager)
        case .scriptLibrary:
            ScriptLibraryView(server: server)
        case .firewall:
            FirewallView(server: server)
        case .database:
            DatabasesView(server: server)
        case .terminal:
            TerminalHostsView(server: server, localTitle: manager.current?.name)
        case .process:
            ProcessView(server: server)
        case .diskManage:
            DisksView(server: server)
        case .sshService:
            SSHView(server: server)
        case .fail2ban:
            Fail2banView(server: server)
        case .ftp:
            FTPView(server: server)
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
        case .panelSettings:
            // 设置 Hub：基础设置 / 告警通知 / 备份账号 / 许可证（对齐网页端面板菜单）
            ManageHubView(title: L10n.t("设置"), items: [.basicSettings, .alert, .backupAccount, .license])
        case .basicSettings:
            PanelBasicSettingsView(server: server)
        case .license:
            LicenseView(server: server)
        }
    }
}

// MARK: - 二级功能 Hub

/// 管理页二级功能中间层（如 网站→[网站/证书]、计划任务→[计划任务/脚本库]），
/// 入口行与管理页列表同款样式；子项为不在管理根列表的隐藏 ManageItem。
/// 消费「自定义功能」隐藏偏好：从根列表移入 Hub 的子项（如告警/备份账号）
/// 不能对老用户的隐藏设置无条件复活
struct ManageHubView: View {
    let title: String
    let items: [ManageItem]
    @EnvironmentObject private var prefs: ManagePrefs

    init(title: String, items: [ManageItem]) {
        self.title = title
        self.items = items
    }

    var body: some View {
        List {
            Section {
                ForEach(items.filter { prefs.isEnabled($0) }) { item in
                    NavigationLink(value: item) {
                        HStack(spacing: 14) {
                            IconBadge(systemName: item.icon, color: item.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                Text(item.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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
                            manageEditRow(item)
                        }
                    } header: {
                        if !group.title.isEmpty {
                            Text(group.title)
                        }
                    }
                }

                // Hub 二级子项：不占管理根列表，但同样受「自定义功能」控制
                // （告警/备份账号等移入 Hub 后，老的隐藏偏好要能继续生效与修改）
                Section(L10n.t("二级功能")) {
                    ForEach(ManageItem.hubChildren) { item in
                        manageEditRow(item)
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

    /// 单个功能的显示/隐藏行（根列表项与 Hub 二级子项共用）
    private func manageEditRow(_ item: ManageItem) -> some View {
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
    /// 网站列表（Hub 子页；首页网站卡片也直达此处，跳过 Hub）
    case websiteList
    /// 证书（Hub 子页；原网站页菜单里的「SSL证书」移出改名）
    case certificates
    case database
    case containers
    case terminal
    case files
    case monitor
    case process
    case diskManage
    case sshService
    case firewall
    case fail2ban
    /// FTP（工具箱；未安装跳脚本库）
    case ftp
    case waf
    case alert
    case nodeManage
    case backupAccount
    case cronjob
    /// 计划任务列表（Hub 子页）
    case cronjobList
    /// 脚本库（Hub 子页；原计划任务 + 菜单入口移出）
    case scriptLibrary
    case taskCenter
    case logs
    case websiteMonitor
    case wafMonitor
    /// 设置（Hub 子页：基础设置 / 告警通知 / 备份账号 / 许可证）
    case panelSettings
    /// 基础设置（设置 Hub 子页）
    case basicSettings
    /// 许可证（设置 Hub 子页）
    case license

    var id: String { rawValue }

    /// 二级 Hub 子项：不在管理根列表展示（经 Hub 中间层进入），
    /// 但可在「自定义功能」中单独隐藏（含从根列表移入的老项，如告警/备份账号）
    static var hubChildren: [ManageItem] {
        [.websiteList, .certificates, .cronjobList, .scriptLibrary,
         .basicSettings, .alert, .backupAccount, .license]
    }

    /// 管理页分组（带标题），ManageTab 与「自定义功能」编辑页共用。
    /// 计算属性而非 static let：L10n 语言偏好可能在首次访问后才就绪/切换，
    /// 缓存会把启动初期的中文标题固化到英文界面
    static var groups: [(title: String, items: [ManageItem])] {
        [
            (L10n.t("应用"), [.apps, .websites, .database, .containers]),
            // SSH 服务管理收进「SSH」页三点菜单（服务管理入口）；进程/磁盘管理移入工具箱
            (L10n.t("主机"), [.terminal, .files, .monitor, .firewall]),
            (L10n.t("工具箱"), [.fail2ban, .ftp, .process, .diskManage]),
            (L10n.t("高级功能"), [.websiteMonitor, .nodeManage, .wafMonitor]),
            // 告警通知 / 备份账号 / 许可证收进「设置」Hub（对齐网页端面板菜单）
            (L10n.t("面板"), [.panelSettings, .cronjob, .taskCenter, .logs]),
        ]
    }

    var title: String {
        switch self {
        case .apps:        return L10n.t("应用程序")
        case .websites:    return L10n.t("网站")
        case .websiteList: return L10n.t("网站")
        case .certificates: return L10n.t("证书")
        case .database:    return L10n.t("数据库")
        case .containers:  return L10n.t("容器")
        case .terminal:    return L10n.t("SSH")
        case .files:       return L10n.t("文件")
        case .monitor:     return L10n.t("监控")
        case .process:     return L10n.t("进程")
        case .diskManage:  return L10n.t("磁盘管理")
        case .sshService:  return L10n.t("服务管理")
        case .firewall:    return L10n.t("防火墙")
        case .fail2ban:    return "Fail2ban"
        case .ftp:         return "FTP"
        case .waf:         return "WAF"
        case .alert:       return L10n.t("告警通知")
        case .nodeManage:  return L10n.t("多机管理")
        case .backupAccount: return L10n.t("备份账号")
        case .cronjob:     return L10n.t("计划任务")
        case .cronjobList: return L10n.t("计划任务")
        case .scriptLibrary: return L10n.t("脚本库")
        case .taskCenter:  return L10n.t("任务中心")
        case .logs:        return L10n.t("日志")
        case .websiteMonitor: return L10n.t("网站监控")
        case .wafMonitor:  return L10n.t("WAF 监控")
        case .panelSettings: return L10n.t("设置")
        case .basicSettings: return L10n.t("基础设置")
        case .license:     return L10n.t("许可证")
    }
    }

    var subtitle: String {
        switch self {
        case .apps:        return L10n.t("已安装应用 / 应用商店")
        case .websites:    return L10n.t("网站 / 证书")
        case .websiteList: return L10n.t("网站列表与创建")
        case .certificates: return L10n.t("SSL 证书 / Acme / DNS")
        case .database:    return L10n.t("管理数据库实例")
        case .containers:  return L10n.t("Docker 容器")
        case .terminal:    return L10n.t("本机终端 / SSH 连接主机")
        case .files:       return L10n.t("服务器文件管理")
        case .monitor:     return L10n.t("负载 / CPU / 内存 / I/O / 网络")
        case .process:     return L10n.t("系统进程监控")
        case .diskManage:  return L10n.t("磁盘 / 分区 / 挂载点")
        case .sshService:  return L10n.t("面板主机 SSH 服务与配置")
        case .firewall:    return L10n.t("防火墙规则")
        case .fail2ban:    return L10n.t("SSH 防暴力破解")
        case .ftp:         return L10n.t("FTP 账号管理")
        case .waf:         return L10n.t("Web 应用防火墙")
        case .alert:       return L10n.t("告警规则 / 日志 / 发送方式")
        case .nodeManage:  return L10n.t("节点概览 / 添加节点 / 切换（专业版）")
        case .backupAccount: return L10n.t("MINIO / WebDAV / SFTP 备份存储")
        case .cronjob:     return L10n.t("计划任务 / 脚本库")
        case .cronjobList: return L10n.t("定时备份与脚本执行")
        case .scriptLibrary: return L10n.t("系统脚本同步 / 自定义脚本")
        case .taskCenter:  return L10n.t("应用同步 / 镜像拉取等异步任务")
        case .logs:        return L10n.t("面板 / SSH / 网站日志")
        case .websiteMonitor: return L10n.t("QPS / 访客趋势 / 访客地图 / 请求日志")
        case .wafMonitor:  return L10n.t("拦截趋势 / 拦截记录 / 封锁记录")
        case .panelSettings: return L10n.t("告警通知 / 备份账号 / 许可证")
        case .basicSettings: return L10n.t("面板别名 / 超时 / 代理 / 运行环境")
        case .license:     return L10n.t("专业版授权绑定 / 同步")
        }
    }

    var icon: String {
        switch self {
        case .apps:        return "app.badge"
        case .websites:    return "globe"
        case .websiteList: return "globe"
        case .certificates: return "lock.shield"
        case .database:    return "cylinder"
        case .containers:  return "shippingbox"
        case .terminal:    return "terminal"
        case .files:       return "folder.fill"
        case .monitor:     return "chart.line.uptrend.xyaxis"
        case .process:     return "chart.bar"
        case .diskManage:  return "internaldrive"
        case .sshService:  return "gearshape.2"
        case .firewall:    return "flame"
        case .fail2ban:    return "shield.lefthalf.filled"
        case .ftp:         return "arrow.up.arrow.down"
        case .waf:         return "flame.fill"
        case .alert:       return "bell.badge.fill"
        case .nodeManage:  return "server.rack"
        case .backupAccount: return "externaldrive.badge.icloud"
        case .cronjob:     return "clock.badge.checkmark"
        case .cronjobList: return "clock.badge.checkmark"
        case .scriptLibrary: return "books.vertical"
        case .taskCenter:  return "checklist"
        case .logs:        return "doc.text.magnifyingglass"
        case .websiteMonitor: return "chart.pie.fill"
        case .wafMonitor:  return "chart.bar.xaxis"
        case .panelSettings: return "gearshape.fill"
        case .basicSettings: return "slider.horizontal.3"
        case .license:     return "checkmark.seal.fill"
        }
    }

    var color: Color {
        switch self {
        case .apps:        return .blue
        case .websites:    return .green
        case .websiteList: return .green
        case .certificates: return .blue
        case .database:    return .purple
        case .containers:  return .indigo
        case .terminal:    return .primary  // 深色模式下 .black 图标不可见，改用自适应色
        case .files:       return .yellow
        case .monitor:     return .mint
        case .process:     return .pink
        case .sshService:  return .blue
        case .firewall:    return .orange
        case .fail2ban:    return .indigo
        case .ftp:         return .teal
        case .waf:         return .red
        case .alert:       return .orange
        case .nodeManage:  return .teal
        case .backupAccount: return .blue
        case .cronjob:     return .teal
        case .cronjobList: return .teal
        case .scriptLibrary: return .purple
        case .taskCenter:  return .brown
        case .logs:        return .cyan
        case .websiteMonitor: return .indigo
        case .wafMonitor:  return .red
        case .panelSettings: return .blue
        case .basicSettings: return .teal
        case .license:     return .orange
        case .diskManage:  return .gray
        }
    }

    var available: Bool { true }
}
