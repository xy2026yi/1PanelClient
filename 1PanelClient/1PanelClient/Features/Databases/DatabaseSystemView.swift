//
//  DatabaseSystemView.swift
//  1PanelClient
//
//  单个数据库系统详情视图 + 连接信息页 + 用户行（自 DatabasesView.swift 拆出，内容未改动）
//

import SwiftUI
import Combine

// MARK: - 单个数据库系统详情视图

struct DatabaseSystemView: View {
    @StateObject private var vm: DatabaseSystemViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCreate = false
    @State private var showConnInfo = false
    @State private var showRedisTerminal = false
    @State private var showDatabaseTerminal = false
    /// MySQL/MariaDB 状态（databases/status）
    @State private var showMySQLStatus = false
    /// MySQL/MariaDB 参数（databases/variables）
    @State private var showMySQLVariables = false
    /// MySQL/MariaDB 性能调整（优化方案预设）
    @State private var showMySQLPerformance = false
    /// MySQL/MariaDB 配置修改（my.cnf）
    @State private var showMySQLConf = false
    /// Redis 状态（databases/redis/status）
    @State private var showRedisStatus = false
    /// Redis 性能调整（timeout/maxclients/maxmemory）
    @State private var showRedisPerformance = false
    @State private var showContainerTerminal = false
    @State private var pendingAction: String?
    @State private var pendingDeleteDb: DatabaseItem?
    @State private var isStatusExpanded = false
    @State private var showCreateUser = false
    /// + 号半屏菜单（创建数据库/创建用户，按系统能力显示）
    @State private var showAddMenu = false
    /// + 号半屏菜单项（按系统能力：创建数据库 / 创建用户）
    private var addMenuItems: [ActionMenuItem] {
        var items: [ActionMenuItem] = []
        if vm.supportsDatabaseList {
            items.append(.init(title: L10n.t("创建数据库"), icon: "cylinder", color: .blue) {
                showCreate = true
            })
        }
        if vm.supportsUserManagement {
            items.append(.init(title: L10n.t("创建用户"), icon: "person.badge.plus", color: .blue) {
                showCreateUser = true
            })
        }
        return items
    }

    @State private var pendingDeleteUser: DatabaseUser?
    /// 删除前记录的相邻用户 id：usersReloadToken 整节重建后回滚列表位置
    @State private var usersAnchorID: String?
    @State private var searchText = ""
    @State private var isSearching = false

    /// 库/用户列表按名称过滤（搜索态）
    private var filteredDatabases: [DatabaseItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return vm.databases }
        return vm.databases.filter { ($0.name ?? "").localizedCaseInsensitiveContains(q) }
    }

    private var filteredUsers: [DatabaseUser] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return vm.users }
        return vm.users.filter { ($0.username ?? "").localizedCaseInsensitiveContains(q) }
    }

    init(system: DatabaseSystem) {
        _vm = StateObject(wrappedValue: DatabaseSystemViewModel(system: system, server: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")))
    }

    var body: some View {
        ScrollViewReader { scroller in
        List {
            if vm.isWaitingService {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(L10n.t("等待服务就绪…"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            statusSection
            // 容器已停止：库表/用户等容器内数据不可用（也不再请求），
            // 仅保留状态卡与启动入口，避免空态误导
            if vm.isContainerRunning {
                if vm.supportsDatabaseList {
                    databaseListSection
                }
                if vm.supportsUserManagement {
                    userListSection
                        .id(vm.usersReloadToken)
                }
            }
        }
        .searchIconMode(text: $searchText, isSearching: $isSearching, title: vm.system.displayName, prompt: L10n.t("搜索数据库 / 用户"))
        // 右上角加号（菜单）：与其他列表页 toolbar 创建范式一致，按系统能力显示可用项；
        // 无可创建项（Redis 两类均不支持）或容器停止时不显示空 + 号
        .toolbar {
            if !isSearching && vm.isContainerRunning
                && (vm.supportsDatabaseList || vm.supportsUserManagement) {
                ToolbarItem(placement: .topBarTrailing) {
                    // 单项能力（仅创建数据库，如 PG/MongoDB）直接进入创建页；
                    // 两项能力（MySQL 系）保留半屏菜单
                    Button {
                        if addMenuItems.count == 1, let only = addMenuItems.first {
                            only.action()
                        } else {
                            showAddMenu = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.t("创建"))
                }
            }
        }
        .refreshable { await vm.refresh() }
        .onChange(of: vm.usersReloadToken) { _, _ in
            // 整节身份重建会丢滚动位置：回滚到删除项的相邻行
            if let anchor = usersAnchorID {
                scroller.scrollTo(anchor, anchor: .top)
                usersAnchorID = nil
            }
        }
        .task { await vm.refresh() }
        .sheet(isPresented: $showAddMenu) {
            ActionBottomSheet(title: vm.system.displayName, items: addMenuItems) {
                showAddMenu = false
            }
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: addMenuItems.count))])
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(isPresented: $showCreate) {
            CreateDatabaseView(system: vm.system) { await vm.loadDatabases() }
        }
        .navigationDestination(isPresented: $showCreateUser) {
            CreateDatabaseUserView(system: vm.system, availableDatabases: vm.databases.map { $0.name ?? "" }.filter { !$0.isEmpty }) {
                await vm.loadUsers()
            }
        }
        .navigationDestination(isPresented: $showConnInfo) {
            DatabaseConnInfoView(vm: vm)
        }
        .navigationDestination(isPresented: $showMySQLStatus) {
            DatabaseMySQLStatusView(system: vm.system)
        }
        .navigationDestination(isPresented: $showMySQLVariables) {
            DatabaseMySQLVariablesView(system: vm.system)
        }
        .navigationDestination(isPresented: $showMySQLPerformance) {
            DatabaseMySQLPerformanceView(system: vm.system)
        }
        .navigationDestination(isPresented: $showMySQLConf) {
            DatabaseMySQLConfView(system: vm.system)
        }
        .navigationDestination(isPresented: $showRedisStatus) {
            DatabaseRedisStatusView(system: vm.system)
        }
        .navigationDestination(isPresented: $showRedisPerformance) {
            DatabaseRedisPerformanceView(system: vm.system)
        }
        .navigationDestination(isPresented: $showRedisTerminal) {
            TerminalScreen(
                server: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""),
                target: .redis(name: vm.system.database, cols: 80, rows: 24)
            )
        }
        .navigationDestination(isPresented: $showDatabaseTerminal) {
            TerminalScreen(
                server: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""),
                target: .database(
                    databaseType: vm.system.type,
                    database: vm.system.database,
                    cols: 80, rows: 24
                )
            )
        }
        // MongoDB 无数据库专用终端，进入其容器执行 /bin/sh，
        // 连接就绪后自动下发 mongosh（与网页端行为一致）
        .navigationDestination(isPresented: $showContainerTerminal) {
            if let container = vm.check?.containerName {
                TerminalScreen(
                    server: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""),
                    target: .container(containerID: container, user: "", command: "/bin/sh", cols: 80, rows: 24),
                    initialCommand: vm.mongoInitialCommand
                )
            }
        }
        .alert(
            pendingAction.map { dbActionDisplayName($0) } ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingAction = nil }
            Button(L10n.t("确认"), role: .destructive) {
                Haptic.warning()
                let op = pendingAction
                pendingAction = nil
                if let op { Task { await vm.operate(op) } }
            }
        } message: {
            if let action = pendingAction {
                Text(L10n.f("将对 %@ 进行 %@ 操作，是否继续？", vm.system.displayName, dbActionDisplayName(action)))
            }
        }
        .sheet(item: $pendingDeleteDb) { db in
            TextInputConfirmSheet(
                title: L10n.t("删除数据库"),
                message: L10n.f("此操作不可恢复。请输入数据库名称「%@」以确认删除。", db.name ?? ""),
                expectedText: db.name ?? "",
                fieldLabel: L10n.t("确认名称"),
                fieldPlaceholder: L10n.t("数据库名称")
            ) {
                Task { await vm.deleteDatabase(db) }
            }
        }
        .sheet(item: $pendingDeleteUser) { user in
            TextInputConfirmSheet(
                title: L10n.t("删除用户"),
                message: L10n.f("此操作不可恢复。请输入「%@」以确认删除。", user.displayName),
                expectedText: user.displayName,
                fieldLabel: L10n.t("确认用户名"),
                fieldPlaceholder: L10n.t("用户名@主机")
            ) {
                // 整节重建回滚锚点：记录被删项的前一行（无前则后一行）
                let idx = vm.users.firstIndex(where: { $0.id == user.id }) ?? 0
                if !vm.users.isEmpty {
                    let neighbor = idx > 0 ? vm.users[idx - 1] : vm.users.last
                    usersAnchorID = neighbor?.id
                }
                Task { await vm.deleteUser(user) }
            }
        }
        } // ScrollViewReader
    }

    private func dbActionDisplayName(_ action: String) -> String {
        switch action {
        case "stop":    return L10n.t("停止")
        case "start":   return L10n.t("启动")
        case "restart": return L10n.t("重启")
        default:        return action
        }
    }

    // MARK: 状态卡片（可折叠面板）

    @ViewBuilder
    private var statusSection: some View {
        if let check = vm.check {
            ServiceStatusCard(
                title: check.app ?? vm.system.displayName,
                subtitle: check.version.flatMap { $0.isEmpty ? nil : "v\($0)" },
                statusText: check.isRunning ? L10n.t("运行中") : L10n.t("已停止"),
                statusColor: check.isRunning ? .statusRunning : .statusStopped,
                isOperating: vm.isOperating,
                isExpanded: $isStatusExpanded,
                actions: drawerActions(check)
            ) {
                EmptyView()
            }
        } else {
            Section {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
    }

    /// 抽屉操作：启停/重启/终端 + 连接信息（创建数据库/用户入口在右上角加号菜单）；
    /// MySQL/MariaDB 追加「状态 / 参数 / 性能调整 / 配置修改」四入口
    private func drawerActions(_ check: AppInstallCheck) -> [ServiceAction] {
        var actions: [ServiceAction] = [
            ServiceAction(
                title: check.isRunning ? L10n.t("停止") : L10n.t("启动"),
                icon: check.isRunning ? "stop.fill" : "play.fill",
                color: check.isRunning ? .orange : .green
            ) { pendingAction = check.isRunning ? "stop" : "start" },
            ServiceAction(title: L10n.t("重启"), icon: "arrow.triangle.2.circlepath", color: .blue) {
                pendingAction = "restart"
            },
            ServiceAction(
                title: L10n.t("终端"),
                icon: "terminal",
                color: .teal,
                // 容器内操作：停止态禁用（MongoDB 另加容器名缺失判定）
                isDisabled: !check.isRunning || (vm.isMongoDB && (check.containerName?.isEmpty ?? true))
            ) {
                if vm.isRedis {
                    showRedisTerminal = true
                } else if vm.isMongoDB {
                    showContainerTerminal = true
                } else {
                    showDatabaseTerminal = true
                }
            },
            ServiceAction(title: L10n.t("连接信息"), icon: "link", color: .cyan,
                          isDisabled: !check.isRunning) {
                showConnInfo = true
            },
        ]
        if ["mysql", "mariadb"].contains(vm.system.type.lowercased()) {
            actions.append(ServiceAction(title: L10n.t("状态"), icon: "speedometer", color: .purple,
                                          isDisabled: !check.isRunning) {
                showMySQLStatus = true
            })
            actions.append(ServiceAction(title: L10n.t("参数"), icon: "slider.horizontal.3", color: .indigo,
                                          isDisabled: !check.isRunning) {
                showMySQLVariables = true
            })
            actions.append(ServiceAction(title: L10n.t("性能调整"), icon: "wand.and.stars", color: .mint,
                                          isDisabled: !check.isRunning) {
                showMySQLPerformance = true
            })
            actions.append(ServiceAction(title: L10n.t("配置修改"), icon: "doc.plaintext", color: .brown,
                                          isDisabled: !check.isRunning) {
                showMySQLConf = true
            })
        }
        if vm.system.type.lowercased() == "redis" {
            actions.append(ServiceAction(title: L10n.t("状态"), icon: "speedometer", color: .purple,
                                          isDisabled: !check.isRunning) {
                showRedisStatus = true
            })
            actions.append(ServiceAction(title: L10n.t("性能调整"), icon: "wand.and.stars", color: .mint,
                                          isDisabled: !check.isRunning) {
                showRedisPerformance = true
            })
        }
        return actions
    }

    // MARK: 数据库列表

    private var databaseListSection: some View {
        Section {
            ForEach(filteredDatabases, id: \.id) { db in
                NavigationLink {
                    DatabaseDetailView(database: db, system: vm.system) { await vm.loadDatabases() }
                } label: {
                    DatabaseItemRow(db: db)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDeleteDb = db
                    } label: { Label(L10n.t("删除"), systemImage: "trash") }
                }
                .onAppear {
                    // 触底判定用未过滤列表的末行：过滤后末行可能不可见，
                    // 挂底部的加载行兜底触发；过滤空时若还有未加载页，
                    // 加载行仍渲染、翻页不会被空态卡停
                    if db.id == vm.databases.last?.id {
                        Task { await vm.loadMoreDatabases() }
                    }
                }
            }
            if filteredDatabases.isEmpty {
                ContentUnavailableView {
                    Label(
                        searchText.trimmingCharacters(in: .whitespaces).isEmpty
                            ? L10n.t("暂无数据库") : L10n.t("无匹配的数据库"),
                        systemImage: "tray"
                    )
                }
                .frame(maxWidth: .infinity)
            }
            if vm.databases.count < vm.dbTotal || vm.isLoadingMore {
                LoadingStateView(compact: true)
                .onAppear { Task { await vm.loadMoreDatabases() } }
            }
        } header: {
            // 与防火墙段头同口径：显示总数（max 兜底翻页间隙的瞬时不一致）
            SectionLabel(
                title: L10n.f("数据库（%ld）", max(vm.dbTotal, vm.databases.count)),
                systemImage: "cylinder"
            )
        }
    }

    // MARK: 用户列表（MySQL）

    private var userListSection: some View {
        Section {
            ForEach(filteredUsers, id: \.id) { user in
                NavigationLink {
                    DatabaseUserDetailView(user: user, system: vm.system, availableDatabases: vm.databases.map { $0.name ?? "" }.filter { !$0.isEmpty }) {
                        await vm.loadUsers()
                    }
                } label: {
                    DatabaseUserRow(user: user, grants: vm.databasesForUser(user))
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDeleteUser = user
                    } label: { Label(L10n.t("删除"), systemImage: "trash") }
                }
            }
            if filteredUsers.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("暂无用户"), systemImage: "tray")
                }
                .frame(maxWidth: .infinity)
            }
        } header: {
            SectionLabel(title: L10n.f("用户（%ld）", filteredUsers.count), systemImage: "person.2")
        }
    }
}

// MARK: - 连接信息页（由详情页抽屉「连接信息」进入）

struct DatabaseConnInfoView: View {
    @ObservedObject var vm: DatabaseSystemViewModel
    @State private var showServicePasswordSheet = false
    @State private var showRedisPasswordSheet = false

    var body: some View {
        List {
            Section {
                if let ci = vm.connInfo {
                    CopyableInfoRow(key: L10n.t("容器地址"), value: ci.containerName ?? vm.system.address ?? "-", monospaced: true)
                    if let port = ci.port { CopyableInfoRow(key: L10n.t("端口"), value: "\(port)", monospaced: true) }
                    CopyableInfoRow(key: L10n.t("外部地址"), value: "127.0.0.1", monospaced: true)
                    if let user = ci.username, !user.isEmpty {
                        CopyableInfoRow(key: L10n.t("用户名"), value: user, monospaced: false)
                    }

                    if vm.supportsRemoteAccess {
                        Toggle(isOn: Binding(
                            get: { vm.remoteAccess },
                            set: { on in Task { await vm.toggleRemote(on) } }
                        )) {
                            Label(L10n.t("远程访问"), systemImage: "network")
                        }
                        .disabled(vm.isOperating)
                    }

                    if let pwd = ci.password, !pwd.isEmpty {
                        PasswordRow(password: pwd)
                        Button {
                            if vm.isRedis {
                                showRedisPasswordSheet = true
                            } else {
                                showServicePasswordSheet = true
                            }
                        } label: {
                            Label(L10n.t("修改密码"), systemImage: "key")
                        }
                    }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            } header: {
                SectionLabel(title: L10n.t("连接信息"), systemImage: "link")
            }
        }
        .navigationTitle(L10n.t("连接信息"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            async let conn: () = vm.loadConnInfo()
            async let remote: () = vm.loadRemote()
            _ = await (conn, remote)
        }
        .sheet(isPresented: $showServicePasswordSheet) {
            ChangePasswordSheet(
                title: L10n.f("修改 %@ 密码", vm.system.displayName),
                currentPassword: vm.connInfo?.password
            ) { newPassword in
                Task { await vm.changeServicePassword(newPassword) }
            }
        }
        .sheet(isPresented: $showRedisPasswordSheet) {
            RedisPasswordSheet(
                currentPassword: vm.connInfo?.password
            ) { newPassword in
                Task {
                    let ok = await vm.changeRedisPassword(newPassword)
                    if ok {
                        await vm.operate("restart")
                        await vm.loadConnInfo()
                    }
                }
            }
        }
    }
}

// MARK: - 数据库用户行

struct DatabaseUserRow: View {
    let user: DatabaseUser
    let grants: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(user.displayName)
                    .font(.dataMonospacedBody.bold())
                if let host = user.host, host == "%" {
                    StatusBadge(text: L10n.t("远程"), color: .blue, icon: "network")
                } else {
                    StatusBadge(text: L10n.t("本机"), color: .orange, icon: "lock.shield")
                }
            }

            if let pwd = user.password, !pwd.isEmpty {
                PasswordRow(password: pwd, compact: true)
            }

            if !grants.isEmpty {
                HStack(spacing: 4) {
                    Text(L10n.t("数据库:")).font(.caption).foregroundStyle(.secondary)
                    Text(grants.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if let desc = user.description, !desc.isEmpty {
                Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 数据库行

struct DatabaseItemRow: View {
    let db: DatabaseItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(db.name ?? "-")
                    .font(.dataMonospacedBody.bold())
                // MongoDB 无 permission 字段，不显示本机/远程徽标
                if !db.isMongoDB {
                    if let perm = db.permission, perm == "%" || perm.isEmpty {
                        StatusBadge(text: L10n.t("远程"), color: .blue, icon: "network")
                    } else {
                        StatusBadge(text: L10n.t("本机"), color: .orange, icon: "lock.shield")
                    }
                }
            }
            if let desc = db.description, !desc.isEmpty {
                Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                if let u = db.username, !u.isEmpty {
                    Text(L10n.f("用户: %@", u)).font(.caption).foregroundStyle(.secondary)
                }
                if let f = db.format, !f.isEmpty {
                    Text(f).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 修改密码 Sheet

struct ChangePasswordSheet: View {
    let title: String
    let currentPassword: String?
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newPassword = ""
    @State private var showCurrent = false
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            Form {
                if let cur = currentPassword, !cur.isEmpty {
                    Section(L10n.t("当前密码")) {
                        HStack {
                            Text(showCurrent ? cur : String(repeating: "•", count: min(cur.count, 12)))
                                .font(.dataMonospacedBody)
                            Spacer()
                            Button { showCurrent.toggle() } label: {
                                Image(systemName: showCurrent ? "eye.slash" : "eye")
                            }.accessibilityLabel(showCurrent ? L10n.t("隐藏密码") : L10n.t("显示密码"))
                            Button { UIPasteboard.general.string = cur } label: {
                                Image(systemName: "doc.on.doc")
                            }.accessibilityLabel(L10n.t("复制密码"))
                        }
                    }
                }
                Section(L10n.t("新密码")) {
                    // 眼睛 + 骰子内嵌描边框右侧（borderless：Form 行内多按钮
                    // 默认样式会整行同触——点眼睛曾连带触发随机生成并强制明文）
                    OutlinedShape(label: L10n.t("新密码"), isFocused: false,
                                  hasValue: !newPassword.isEmpty,
                                  trailing: {
                        HStack(spacing: 10) {
                            Button { showNew.toggle() } label: {
                                Image(systemName: showNew ? "eye.slash" : "eye")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(showNew ? L10n.t("隐藏密码") : L10n.t("显示密码"))
                            Button {
                                newPassword = randomPassword()
                                showNew = true
                            } label: {
                                Image(systemName: "dice")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.t("生成随机密码"))
                        }
                    }) {
                        Group {
                            if showNew {
                                TextField("", text: $newPassword)
                            } else {
                                SecureField("", text: $newPassword)
                            }
                        }
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("保存")) {
                        onConfirm(newPassword)
                        dismiss()
                    }
                    .disabled(newPassword.isEmpty)
                }
            }
        }
    }

    private func randomPassword() -> String {
        let chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<16).map { _ in chars.randomElement()! })
    }
}

// MARK: - Redis 密码修改 Sheet（两步：输入密码 → 确认重启）

struct RedisPasswordSheet: View {
    let currentPassword: String?
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newPassword = ""
    @State private var showCurrent = false
    @State private var showNew = false
    @State private var step: Step = .input
    @State private var restartConfirm = ""

    enum Step { case input, confirm }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .input: inputStep
                case .confirm: confirmStep
                }
            }
            .navigationTitle(L10n.t("修改 Redis 密码"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if step == .input {
                        Button(L10n.t("下一步")) {
                            step = .confirm
                        }
                        .disabled(newPassword.isEmpty)
                    } else {
                        Button(L10n.t("立即重启"), role: .destructive) {
                            Haptic.warning()
                            onConfirm(newPassword)
                            dismiss()
                        }
                        .disabled(restartConfirm != L10n.t("立即重启"))
                    }
                }
            }
        }
    }

    private var inputStep: some View {
        Form {
            if let cur = currentPassword, !cur.isEmpty {
                Section(L10n.t("当前密码")) {
                    HStack {
                        Text(showCurrent ? cur : String(repeating: "•", count: min(cur.count, 12)))
                            .font(.dataMonospacedBody)
                        Spacer()
                        Button { showCurrent.toggle() } label: {
                            Image(systemName: showCurrent ? "eye.slash" : "eye")
                        }.accessibilityLabel(showCurrent ? L10n.t("隐藏密码") : L10n.t("显示密码"))
                        Button { UIPasteboard.general.string = cur } label: {
                            Image(systemName: "doc.on.doc")
                        }.accessibilityLabel(L10n.t("复制密码"))
                    }
                }
            }
            Section(L10n.t("新密码")) {
                OutlinedShape(label: L10n.t("新密码"), isFocused: false,
                              hasValue: !newPassword.isEmpty,
                              trailing: {
                    HStack(spacing: 10) {
                        Button { showNew.toggle() } label: {
                            Image(systemName: showNew ? "eye.slash" : "eye")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showNew ? L10n.t("隐藏密码") : L10n.t("显示密码"))
                        Button {
                            newPassword = randomPassword()
                        } label: {
                            Image(systemName: "dice")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.t("生成随机密码"))
                    }
                }) {
                    Group {
                        if showNew {
                            TextField("", text: $newPassword)
                        } else {
                            SecureField("", text: $newPassword)
                        }
                    }
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                }
            }
        }
    }

    private var confirmStep: some View {
        Form {
            Section {
                Label(L10n.t("修改密码后需要重启 Redis 才能生效"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(L10n.t("请输入「立即重启」以确认操作。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section(L10n.t("确认重启")) {
                OutlinedTextField(label: L10n.t("立即重启"), prompt: L10n.t("立即重启"), text: $restartConfirm, machineValue: false)
            }
        }
    }

    private func randomPassword() -> String {
        let chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<16).map { _ in chars.randomElement()! })
    }
}

// MARK: - 半屏确认删除 Sheet（数据库 / 用户）

