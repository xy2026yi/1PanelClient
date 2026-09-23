//
//  WebsiteExtraViews.swift
//  1PanelClient
//
//  网站扩展功能页（依据 logs/网站修改与增加-1.md 抓包 2026-09-17）：
//  域名设置 / 防盗链 / 伪静态 / 真实 IP / 跨域访问 / 负载均衡 / 其他（基础信息）。
//

import SwiftUI

// MARK: - 域名设置

/// 域名列表：域名/端口/SSL（端口 80 不可开）/删除（仅剩一个不可删）+ 新增域名
struct WebsiteDomainsView: View {
    let websiteId: Int
    @ObservedObject var vm: WebsitesViewModel

    @State private var domains: [WebsiteDomainItem] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var pendingDelete: WebsiteDomainItem?
    @State private var switchingID: Int?
    @State private var showAdd = false

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else if let err = loadError {
                LoadErrorStateView(message: err) { Task { await load() } }
            } else {
                list
            }
        }
        .navigationTitle(L10n.t("域名设置"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("新增域名"))
            }
        }
        .navigationDestination(isPresented: $showAdd) {
            WebsiteDomainAddView(websiteId: websiteId, vm: vm) {
                Task { await load() }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .alert(L10n.t("删除域名"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDelete = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                if let d = pendingDelete {
                    pendingDelete = nil
                    Task { await delete(d) }
                }
            }
        } message: {
            if let d = pendingDelete {
                Text(L10n.f("确定删除域名「%@」吗？删除后不可恢复。", d.domain ?? ""))
            }
        }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: { Text(vm.alertMessage) }
    }

    private var list: some View {
        List {
            Section {
                ForEach(domains) { d in
                    row(d)
                }
            } footer: {
                Text(L10n.t("端口为 80 的域名不可开启 SSL；仅剩一个域名时不可删除"))
            }
        }
    }

    private func row(_ d: WebsiteDomainItem) -> some View {
        HStack {
            // 域名+端口同行（example.com:8080）
            Text("\(d.domain ?? "—"):\(d.port ?? 80)")
                .font(.body.bold().monospaced())
            Spacer()
            if d.id == switchingID {
                ProgressView().controlSize(.small)
            } else {
                Toggle("", isOn: Binding(
                    get: { d.ssl ?? false },
                    set: { on in Task { await toggleSSL(d, on: on) } }
                ))
                .labelsHidden()
                .disabled((d.port ?? 80) == 80)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = d
            } label: {
                Label(L10n.t("删除"), systemImage: "trash")
            }
            .disabled(domains.count <= 1)
        }
    }

    private func load() async {
        isLoading = domains.isEmpty
        // loadWebsiteDomains 内部消化错误（失败弹 alert、返回空数组），无需 do/catch
        domains = await vm.loadWebsiteDomains(websiteId: websiteId)
        isLoading = false
    }

    private func toggleSSL(_ d: WebsiteDomainItem, on: Bool) async {
        guard let domainID = d.id else { return }
        switchingID = d.id
        defer { switchingID = nil }
        if await vm.updateDomainSSL(id: domainID, ssl: on) {
            await load()
        }
    }

    private func delete(_ d: WebsiteDomainItem) async {
        guard let domainID = d.id else { return }
        if await vm.deleteDomain(id: domainID) {
            await load()
        }
    }
}

// MARK: - 新增域名

/// 新增域名表单：域名（主机名自动带入、不可改）/ 端口（默认 80）/ SSL（默认关）
/// POST /websites/domains {websiteID, domains[], domainStr:""}（抓包 2026-09-23）
struct WebsiteDomainAddView: View {
    let websiteId: Int
    @ObservedObject var vm: WebsitesViewModel
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var domain = ""
    @State private var port = 80
    @State private var ssl = false
    @State private var isSubmitting = false

    /// 主机名 = 域名（去端口后缀），与提交的 host 一致；域名输入自动带入、不可修改
    private var host: String {
        domain.split(separator: ":").first.map(String.init) ?? domain
    }

    /// 端口 String ↔ Int（描边框接收 String；非法输入保留原值）
    private var portText: Binding<String> {
        Binding<String>(get: { String(port) }, set: { port = Int($0) ?? port })
    }

    private var canSubmit: Bool {
        !domain.trimmingCharacters(in: .whitespaces).isEmpty && !isSubmitting
    }

    var body: some View {
        Form {
            Section {
                OutlinedTextField(label: L10n.t("域名"), prompt: "example.com",
                                  text: $domain, keyboardType: .URL)

                OutlinedTextField(label: L10n.t("主机名"), text: .constant(host),
                                  disabled: true)

                OutlinedUnitField(label: L10n.t("端口"), unit: "",
                                  text: portText, range: 1...65535,
                                  keyboardType: .numberPad)

                Toggle(L10n.t("SSL"), isOn: $ssl)
            } footer: {
                Text(L10n.t("端口为 80 的域名不可开启 SSL"))
            }
        }
        .navigationTitle(L10n.t("新增域名"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.t("添加")) {
                    Task { await submit() }
                }
                .disabled(!canSubmit)
            }
        }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: { Text(vm.alertMessage) }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        // 端口 80 不允许开 SSL（服务端约束，提前按表单联动收口）
        let effectiveSSL = (port == 80) ? false : ssl
        if await vm.addWebsiteDomain(websiteId: websiteId, domain: domain,
                                     port: port, ssl: effectiveSSL) {
            onDone()
            dismiss()
        }
    }
}

// MARK: - 分组选择（创建网站 / 其他 共用）

/// 表单级分组菜单（形态 2 描边菜单）；分组数据未加载时回落「默认分组」占位行。
/// 选中值不在列表（分组被删）时回落 0（默认分组）
struct WebsiteGroupPicker: View {
    @Binding var selection: Int
    let groups: [PanelGroup]

    var body: some View {
        if groups.isEmpty {
            HStack {
                Text(L10n.t("分组")).foregroundStyle(.secondary)
                Spacer()
                Text(L10n.t("默认分组")).foregroundStyle(.secondary)
            }
        } else {
            OutlinedPicker(label: L10n.t("分组"),
                           options: optionKeys,
                           selection: selectionText,
                           optionLabels: optionLabels)
        }
    }

    private var optionKeys: [String] {
        ["0"] + groups.map { String($0.id) }
    }

    private var optionLabels: [String: String] {
        var labels = ["0": L10n.t("默认分组")]
        for g in groups { labels[String(g.id)] = g.displayName }
        return labels
    }

    private var selectionText: Binding<String> {
        Binding<String>(
            get: {
                selection != 0 && groups.contains(where: { $0.id == selection })
                    ? String(selection) : "0"
            },
            set: { selection = Int($0) ?? 0 }
        )
    }
}

// MARK: - PHP 运行环境（三点菜单子页）

/// 静态网站 ↔ PHP 运行环境切换（POST /websites/php/version）；
/// 切换成功后回调父页重载详情（详情 sections 随 type 变化）
struct WebsitePHPView: View {
    let website: Website
    @ObservedObject var vm: WebsitesViewModel
    var onChanged: () -> Void

    @State private var currentType = ""
    @State private var currentRuntimeID = 0
    @State private var phpRuntimes: [RuntimeItem] = []
    @State private var isSwitching = false
    // 防跨站攻击（open_basedir，仅运行环境类型；随 PHP 走）
    @State private var openBaseDir = false
    @State private var isTogglingCrosssite = false

    var body: some View {
        Form {
            Section {
                if isSwitching {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else {
                    OutlinedPicker(label: L10n.t("PHP"),
                                   options: optionKeys,
                                   selection: outlinedBinding,
                                   optionLabels: optionLabels)
                }
            } footer: {
                Text(L10n.t("切换为运行环境后网站由 PHP 运行环境接管；切回「静态网站」脱离运行环境"))
            }

            if currentType == "runtime" {
                Section {
                    Toggle(L10n.t("防跨站攻击"), isOn: Binding(
                        get: { openBaseDir },
                        set: { on in Task { await toggleCrosssite(on) } }
                    ))
                    .disabled(isTogglingCrosssite)
                } footer: {
                    Text(L10n.t("open_basedir 限制 PHP 只能访问站点目录，防止跨站读写"))
                }
            }
        }
        .navigationTitle("PHP")
        .navigationBarTitleDisplayMode(.inline)
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: { Text(vm.alertMessage) }
        .task { await load() }
    }

    /// 选项键：0=静态网站；rt-{id}=运行环境（前缀避免与静态键/缺省 id 撞车，重复键去重）
    private var optionKeys: [String] {
        var keys = ["0"]
        var seen: Set<String> = ["0"]
        for r in phpRuntimes {
            let key = "rt-\(r.id ?? 0)"
            if seen.insert(key).inserted { keys.append(key) }
        }
        return keys
    }

    private var optionLabels: [String: String] {
        var labels = ["0": L10n.t("静态网站")]
        for r in phpRuntimes { labels["rt-\(r.id ?? 0)"] = r.displayName }
        return labels
    }

    private var outlinedBinding: Binding<String> {
        Binding<String>(
            get: { currentType == "runtime" ? "rt-\(currentRuntimeID)" : "0" },
            set: { newValue in
                let idString = newValue.hasPrefix("rt-") ? String(newValue.dropFirst(3)) : newValue
                Task { await switchPHP(to: Int(idString) ?? 0) }
            }
        )
    }

    private func load() async {
        if let d = await vm.loadDetail(id: website.id) {
            currentType = d.type ?? "static"
            currentRuntimeID = d.runtimeID ?? 0
            openBaseDir = d.openBaseDir ?? false
        }
        // 运行环境列表（type=php）
        let req = RuntimeSearchRequest(page: 1, pageSize: 200, type: "php")
        if let resp: RuntimeSearchResponse = try? await vm.client.send(
            path: APIEndpoint.runtimesSearch.path, body: req,
            as: RuntimeSearchResponse.self) {
            phpRuntimes = resp.items ?? []
        }
    }

    /// 防跨站攻击开关（open_basedir Enable/Disable）
    private func toggleCrosssite(_ on: Bool) async {
        isTogglingCrosssite = true
        defer { isTogglingCrosssite = false }
        let req = WebsiteCrosssiteRequest(websiteID: website.id, operation: on ? "Enable" : "Disable")
        do {
            let _: EmptyResponse = try await vm.client.send(
                path: APIEndpoint.websitesCrosssite.path, body: req,
                as: EmptyResponse.self)
            vm.toastMessage = L10n.t("防跨站攻击已更新")
            openBaseDir = on
        } catch {
            vm.alertMessage = L10n.f("操作失败：%@", error.localizedDescription)
            vm.showAlert = true
        }
    }

    private func switchPHP(to newID: Int) async {
        isSwitching = true
        defer { isSwitching = false }
        let req = WebsitePhpVersionRequest(websiteID: website.id, runtimeID: newID)
        do {
            let _: EmptyResponse = try await vm.client.send(
                path: APIEndpoint.websitesPhpVersion.path, body: req,
                as: EmptyResponse.self)
            vm.toastMessage = newID == 0 ? L10n.t("已切回静态网站") : L10n.t("运行环境已切换")
            if let d = await vm.loadDetail(id: website.id) {
                currentType = d.type ?? "static"
                currentRuntimeID = d.runtimeID ?? 0
                openBaseDir = d.openBaseDir ?? false
            }
            onChanged()
        } catch {
            vm.alertMessage = L10n.f("切换失败：%@", error.localizedDescription)
            vm.showAlert = true
        }
    }
}

// MARK: - 资源（关联数据库，三点菜单子页）

/// 网站关联数据库切换（POST /websites/databases）；切换成功后回调父页重载详情
struct WebsiteResourceView: View {
    let website: Website
    @ObservedObject var vm: WebsitesViewModel
    var onChanged: () -> Void

    @State private var dbID = 0
    @State private var databaseOptions: [WebsiteDatabaseOption] = []
    @State private var isSwitching = false

    var body: some View {
        Form {
            Section {
                if isSwitching {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else {
                    OutlinedPicker(label: L10n.t("关联数据库"),
                                   options: optionKeys,
                                   selection: outlinedBinding,
                                   optionLabels: optionLabels)
                }
            } footer: {
                Text(L10n.t("网站关联数据库后便于备份与迁移时一并处理"))
            }
        }
        .navigationTitle(L10n.t("资源"))
        .navigationBarTitleDisplayMode(.inline)
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: { Text(vm.alertMessage) }
        .task { await load() }
    }

    /// 选项键：0=不关联；customID（id+实例名）复合键——不同类型实例 id 可能重复
    /// （如 mysql/mariadb 各有 id=1），复合键保证唯一
    private var optionKeys: [String] {
        var keys = ["0"]
        var seen: Set<String> = ["0"]
        for db in databaseOptions {
            if seen.insert(db.customID).inserted { keys.append(db.customID) }
        }
        return keys
    }

    private var optionLabels: [String: String] {
        var labels = ["0": L10n.t("不关联数据库")]
        for db in databaseOptions { labels[db.customID] = db.displayName }
        return labels
    }

    private var outlinedBinding: Binding<String> {
        Binding<String>(
            get: {
                guard dbID != 0,
                      let match = databaseOptions.first(where: { $0.id == dbID })
                else { return "0" }
                return match.customID
            },
            set: { key in
                let newID = databaseOptions.first { $0.customID == key }?.id ?? 0
                Task { await switchDatabase(to: newID) }
            }
        )
    }

    private func load() async {
        if let d = await vm.loadDetail(id: website.id) {
            dbID = d.dbID ?? 0
        }
        if let list: [WebsiteDatabaseOption] = try? await vm.client.send(
            path: APIEndpoint.websitesDatabases.path, method: "GET",
            as: [WebsiteDatabaseOption].self) {
            databaseOptions = list
        }
    }

    private func switchDatabase(to newID: Int) async {
        isSwitching = true
        defer { isSwitching = false }
        let option = databaseOptions.first { ($0.id ?? 0) == newID }
        let req = WebsiteDatabaseSwitchRequest(
            websiteID: website.id,
            databaseID: newID,
            databaseType: option?.type ?? "",
            db: newID == 0 ? "0" : (option.map { "\(($0.id ?? 0))\($0.name ?? "")" } ?? ""))
        do {
            let _: EmptyResponse = try await vm.client.send(
                path: APIEndpoint.websitesDatabases.path, method: "POST", body: req,
                as: EmptyResponse.self)
            vm.toastMessage = L10n.t("关联数据库已更新")
            dbID = newID
            onChanged()
        } catch {
            vm.alertMessage = L10n.f("切换失败：%@", error.localizedDescription)
            vm.showAlert = true
        }
    }
}

// MARK: - 防盗链

struct WebsiteLeechView: View {
    let websiteId: Int
    @ObservedObject var vm: WebsitesViewModel

    @State private var config = WebsiteLeechConfig()
    @State private var domainsText = ""
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isSaving = false

    private let defaultExtends = "js,css,png,jpg,jpeg,gif,webp,webm,avif,ico,bmp,swf,eot,svg,ttf,woff,woff2"

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else if let err = loadError {
                LoadErrorStateView(message: err) { Task { await load() } }
            } else {
                form
            }
        }
        .navigationTitle(L10n.t("防盗链"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSaving ? L10n.t("保存中…") : L10n.t("保存")) { Task { await save() } }
                    .disabled(isSaving)
            }
        }
        .task { await load() }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: { Text(vm.alertMessage) }
    }

    private var form: some View {
        Form {
            Section {
                OutlinedTextField(label: L10n.t("扩展名"), text: extendBinding)
            } footer: {
                Text(L10n.t("受防盗链约束的文件扩展名，逗号分隔"))
            }

            Section(L10n.t("防盗链")) {
                Toggle(L10n.t("是否启用"), isOn: $config.enable)
                if config.enable {
                    OutlinedMultiLineField(label: L10n.t("允许的域名"),
                                           prompt: "abc.test.com",
                                           text: $domainsText)
                    Toggle(L10n.t("允许 Referer 为空"), isOn: $config.noneRef)
                    Toggle(L10n.t("允许非标准 Referer"), isOn: $config.blocked)
                    OutlinedPicker(label: L10n.t("响应资源"), options: ["404", "400", "403"],
                                   selection: returnBinding)
                }
            }

            Section(L10n.t("缓存控制")) {
                Toggle(L10n.t("浏览器缓存"), isOn: $config.cache)
                if config.cache {
                    OutlinedUnitField(label: L10n.t("缓存时间"), unit: L10n.t("天"),
                                      text: cacheTimeText, range: 1...3650)
                }
                Toggle(L10n.t("记录请求日志"), isOn: $config.logEnable)
            }
        }
    }

    private var extendBinding: Binding<String> {
        Binding(get: { config.extends.isEmpty ? defaultExtends : config.extends },
                set: { config.extends = $0 })
    }

    private var returnBinding: Binding<String> {
        Binding(get: { config.return.isEmpty ? "404" : config.return },
                set: { config.return = $0 })
    }

    private var cacheTimeText: Binding<String> {
        Binding(get: { String(config.cacheTime) },
                set: { config.cacheTime = Int($0) ?? config.cacheTime })
    }

    private func load() async {
        do {
            let c = try await vm.loadLeech(websiteId: websiteId)
            config = c
            domainsText = c.serverNames.joined(separator: "\n")
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let names = domainsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let req = WebsiteLeechUpdateRequest(
            enable: config.enable, cache: config.cache,
            cacheTime: config.cacheTime, cacheUint: config.cache ? "d" : "",
            extends: extendBinding.wrappedValue,
            return: returnBinding.wrappedValue,
            domains: names.joined(separator: "\n"),
            noneRef: config.noneRef, logEnable: config.logEnable,
            blocked: config.blocked, serverNames: names, websiteID: websiteId)
        _ = await vm.updateLeech(req)
        await load()
    }
}

// MARK: - 伪静态

struct WebsiteRewriteView: View {
    let websiteId: Int
    @ObservedObject var vm: WebsitesViewModel

    @State private var selectedName = "current"
    @State private var content = ""
    @State private var originalContent = ""
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var showTemplateSheet = false
    @State private var templateName = ""

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else if let err = loadError {
                LoadErrorStateView(message: err) { Task { await load() } }
            } else {
                form
            }
        }
        .navigationTitle(L10n.t("伪静态"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await save() }
                    } label: {
                        Label(L10n.t("保存并重载"), systemImage: "arrow.clockwise")
                    }
                    .disabled(isSaving || content == originalContent)
                    Button {
                        showTemplateSheet = true
                    } label: {
                        Label(L10n.t("另存为模版"), systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await load() }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: { Text(vm.alertMessage) }
        .sheet(isPresented: $showTemplateSheet) {
            NavigationStack {
                Form {
                    OutlinedTextField(label: L10n.t("名称"), text: $templateName)
                }
                .navigationTitle(L10n.t("另存为模版"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.t("取消")) { showTemplateSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.t("保存")) {
                            Task {
                                if await vm.saveRewriteTemplate(name: templateName, content: content) {
                                    showTemplateSheet = false
                                    templateName = ""
                                }
                            }
                        }
                        .disabled(templateName.isEmpty)
                    }
                }
            }
            .presentationDetents([.height(220)])
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker(L10n.t("方案"), selection: $selectedName) {
                    ForEach(WebsiteRewritePreset.allCases) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }
                .onChange(of: selectedName) { _, newName in
                    Task { await loadContent(name: newName) }
                }
            } footer: {
                Text(L10n.t("若设置伪静态后网站无法正常访问，请尝试设置回 default"))
            }

            Section {
                OutlinedMultiLineField(label: L10n.t("源文"),
                                       lines: 10, fixedLines: 10,
                                       zoomable: true, monospaced: true,
                                       text: $content)
            } header: {
                Text(L10n.t("源文"))
            }
        }
    }

    private func load() async {
        await loadContent(name: selectedName)
        // 基线只在首次进入时记录：切换方案加载新内容后「保存并重载」应可点
        // （应用所选方案本身就是一次保存），仅内容与基线一致且未换方案时才禁用
        originalContent = content
        isLoading = false
    }

    private func loadContent(name: String) async {
        do {
            content = try await vm.loadRewrite(websiteId: websiteId, name: name)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if await vm.updateRewrite(websiteId: websiteId, name: selectedName, content: content) {
            originalContent = content
        }
    }
}

// MARK: - 真实 IP

struct WebsiteRealIPView: View {
    let websiteId: Int
    @ObservedObject var vm: WebsitesViewModel

    @State private var config = WebsiteRealIPConfig()
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isSaving = false

    private let headerOptions = ["X-Real-IP", "X-Forwarded-For", "CF-Connecting-IP", "other"]

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else if let err = loadError {
                LoadErrorStateView(message: err) { Task { await load() } }
            } else {
                form
            }
        }
        .navigationTitle(L10n.t("真实 IP"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSaving ? L10n.t("保存中…") : L10n.t("保存")) { Task { await save() } }
                    .disabled(isSaving)
            }
        }
        .task { await load() }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: { Text(vm.alertMessage) }
    }

    private var form: some View {
        Form {
            Section {
                Toggle(L10n.t("开启"), isOn: $config.open)
                if config.open {
                    OutlinedMultiLineField(label: L10n.t("IP 来源"),
                                           prompt: "127.0.0.1",
                                           text: $config.ipFrom)
                    OutlinedPicker(label: L10n.t("IP Header"), options: headerOptions,
                                   selection: $config.ipHeader)
                    if config.ipHeader == "other" {
                        OutlinedTextField(label: L10n.t("其他 Header"), text: $config.ipOther)
                    }
                }
            }
        }
    }

    private func load() async {
        do {
            config = try await vm.loadRealIP(websiteId: websiteId)
            // 未配置时预填本机回环（与网页端默认一致）
            if config.ipFrom.isEmpty { config.ipFrom = "127.0.0.1" }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        config.websiteID = websiteId
        _ = await vm.updateRealIP(config)
        await load()
    }
}

// MARK: - 跨域访问

struct WebsiteCorsView: View {
    let websiteId: Int
    @ObservedObject var vm: WebsitesViewModel

    @State private var config = WebsiteCorsConfig()
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isSaving = false

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else if let err = loadError {
                LoadErrorStateView(message: err) { Task { await load() } }
            } else {
                form
            }
        }
        .navigationTitle(L10n.t("跨域访问"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSaving ? L10n.t("保存中…") : L10n.t("保存")) { Task { await save() } }
                    .disabled(isSaving)
            }
        }
        .task { await load() }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: { Text(vm.alertMessage) }
    }

    private var form: some View {
        Form {
            Section {
                Toggle(L10n.t("开启跨域"), isOn: $config.cors)
                if config.cors {
                    OutlinedTextField(label: L10n.t("允许访问的域名"), text: $config.allowOrigins)
                    OutlinedTextField(label: L10n.t("允许的请求方式"), text: $config.allowMethods)
                    OutlinedTextField(label: L10n.t("允许的请求头"), text: $config.allowHeaders)
                    Toggle(L10n.t("允许携带 cookies"), isOn: $config.allowCredentials)
                    Toggle(L10n.t("预检请求快速响应"), isOn: $config.preflight)
                }
            }
        }
    }

    private func load() async {
        do {
            config = try await vm.loadCors(websiteId: websiteId)
            // 服务端未配置时返回空串：预填默认值（与网页端一致）
            if config.allowOrigins.isEmpty { config.allowOrigins = "*" }
            if config.allowMethods.isEmpty {
                config.allowMethods = "GET,POST,OPTIONS,PUT,DELETE"
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        config.websiteID = websiteId
        _ = await vm.updateCors(config)
        await load()
    }
}


// MARK: - 其他（基础信息编辑）

/// 名称（primaryDomain，可改）/代号（只读）/分组/备注/监听 IPv6，
/// 提交走 /websites/update（WebsiteUpdateRequest 全量回填）
struct WebsiteOtherView: View {
    let website: Website
    @ObservedObject var vm: WebsitesViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var primaryDomain = ""
    @State private var remark = ""
    @State private var ipv6 = false
    @State private var selectedGroupID = 0
    @State private var detail: WebsiteFull?
    @State private var isLoading = true
    @State private var isSaving = false

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else {
                form
            }
        }
        .navigationTitle(L10n.t("其他"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSaving ? L10n.t("保存中…") : L10n.t("保存")) {
                    Task { await save() }
                }
                .disabled(!canSubmit || isSaving)
            }
        }
        .task {
            if vm.groups.isEmpty { await vm.loadGroups(force: true) }
            await loadDetail()
        }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: { Text(vm.alertMessage) }
    }

    private var form: some View {
        Form {
            Section {
                WebsiteGroupPicker(selection: $selectedGroupID, groups: vm.groups)
                OutlinedTextField(label: L10n.t("名称"), text: $primaryDomain,
                                  keyboardType: .URL)
                // 代号由服务端生成（主目录名），不可修改
                if let alias = detail?.alias, !alias.isEmpty {
                    HStack {
                        Text(L10n.t("代号"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(alias)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Toggle(L10n.t("监听 IPv6"), isOn: $ipv6)
                OutlinedMultiLineField(label: L10n.t("备注"), prompt: L10n.t("可选"),
                                       text: $remark)
            } footer: {
                Text(L10n.t("名称修改后请确保域名解析已指向本服务器"))
            }
        }
    }

    private var canSubmit: Bool {
        !primaryDomain.isEmpty && !primaryDomain.contains(" ")
    }

    private func loadDetail() async {
        do {
            let d = await vm.loadDetail(id: website.id)
            if let d { detail = d
                primaryDomain = d.primaryDomain ?? ""
                remark = d.remark ?? ""
                ipv6 = d.ipv6 ?? false
                selectedGroupID = d.webSiteGroupId ?? 0
            } else {
                vm.alertMessage = vm.detailErrorMessage ?? L10n.t("未知错误")
                vm.showAlert = true
            }
        }
        isLoading = false
    }

    private func save() async {
        guard let d = detail else { return }
        var req = WebsiteUpdateRequest(from: d)
        req.primaryDomain = primaryDomain
        req.remark = remark
        req.ipv6 = ipv6
        req.webSiteGroupID = selectedGroupID != 0 ? selectedGroupID : (d.webSiteGroupId ?? 1)
        let ok = await vm.updateWebsite(req)
        if ok {
            dismiss()
        }
    }
}
