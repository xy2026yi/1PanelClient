//
//  WebsiteConfigViews.swift
//  1PanelClient
//
//  网站详情页三点菜单功能页：默认文档 / 流量限制 / 重定向 / 密码访问。
//  接口字段通过 logs/0818-新增和修改网站-1.md 抓包验证。
//

import SwiftUI

// MARK: - 默认文档

/// 默认文档：每行一个文件名，读取后可编辑，点更新提交并刷新
struct WebsiteDefaultDocView: View {
    let websiteId: Int
    @ObservedObject var vm: WebsitesViewModel

    @State private var docText = ""
    @State private var isLoading = true
    @State private var isSaving = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView(L10n.t("加载中…"))
            } else {
                VStack(spacing: 0) {
                    TextEditor(text: $docText)
                        .font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 4)
                }
                .background(Color(.secondarySystemBackground))
            }
        }
        .navigationTitle(L10n.t("默认文档"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text(L10n.t("更新")).bold()
                    }
                }
                .disabled(isLoading || isSaving || docText.isEmpty)
            }
        }
        .task { await load() }
    }

    private func load() async {
        let resp = await vm.loadWebsiteConfig(
            websiteId: websiteId, scope: "index",
            operate: "update", params: .object([:])
        )
        if let item = resp?.params?.first(where: { $0.name == "index" }) {
            docText = (item.params ?? []).joined(separator: "\n")
        }
        isLoading = false
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await vm.updateWebsiteConfig(
            websiteId: websiteId, operate: "update", scope: "index",
            params: .object(["index": docText])
        )
        if ok {
            await load()
        }
    }
}

// MARK: - 流量限制

/// 流量限制：方案预设填充三个参数，可手动修改；开关与更新分别提交
struct WebsiteLimitConnView: View {
    let websiteId: Int
    @ObservedObject var vm: WebsitesViewModel

    /// 内置限制方案（「当前」仅保持现有值，不参与预设填充）
    private struct LimitScheme: Identifiable {
        let name: String
        let perserver: Int
        let perip: Int
        let rate: Int
        var id: String { name }
    }

    private static let schemes: [LimitScheme] = [
        .init(name: L10n.t("当前"),    perserver: 300, perip: 25, rate: 512),
        .init(name: L10n.t("论坛/博客"), perserver: 300, perip: 25, rate: 512),
        .init(name: L10n.t("图片站"),  perserver: 200, perip: 10, rate: 1024),
        .init(name: L10n.t("下载站"),  perserver: 50,  perip: 3,  rate: 2048),
        .init(name: L10n.t("商城"),    perserver: 500, perip: 10, rate: 2048),
        .init(name: L10n.t("门户"),    perserver: 400, perip: 15, rate: 1024),
        .init(name: L10n.t("企业"),    perserver: 60,  perip: 10, rate: 512),
        .init(name: L10n.t("视频"),    perserver: 150, perip: 4,  rate: 1024),
    ]

    @State private var enable = false
    @State private var schemeIndex = 0
    @State private var perserver = "300"
    @State private var perip = "25"
    @State private var rate = "512"
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isToggling = false

    var body: some View {
        Form {
            Section {
                Toggle(L10n.t("启用"), isOn: Binding(
                    get: { enable },
                    set: { on in Task { await toggle(on) } }
                ))
                .disabled(isToggling)

                Picker(L10n.t("限制方案"), selection: $schemeIndex) {
                    ForEach(Self.schemes.indices, id: \.self) { i in
                        Text(Self.schemes[i].name).tag(i)
                    }
                }
                .onChange(of: schemeIndex) { _, newIndex in
                    // 「当前」保持现有值，其余方案带入内置参数
                    guard newIndex > 0 else { return }
                    let s = Self.schemes[newIndex]
                    perserver = String(s.perserver)
                    perip = String(s.perip)
                    rate = String(s.rate)
                }

                HStack {
                    Text(L10n.t("并发限制"))
                    Spacer()
                    TextField("300", text: $perserver)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 96)
                }
                HStack {
                    Text(L10n.t("单IP限制"))
                    Spacer()
                    TextField("25", text: $perip)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 96)
                }
                HStack {
                    Text(L10n.t("单请求限速"))
                    Spacer()
                    TextField("512", text: $rate)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 96)
                }
            } header: {
                Text(L10n.t("流量限制"))
            } footer: {
                Text(L10n.t("选择限制方案后自动填入内置参数，可手动调整；单请求限速单位为 KB/s"))
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(enable ? L10n.t("保存更新") : L10n.t("启用并更新")).bold()
                        }
                        Spacer()
                    }
                }
                .disabled(isSaving || isLoading)
            }
        }
        .navigationTitle(L10n.t("流量限制"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func buildParams() -> WebsiteConfigParams {
        .array([
            ["limit_conn": "perserver \(perserver)"],
            ["limit_conn": "perip \(perip)"],
            ["limit_rate": "\(rate)k"],
        ])
    }

    private func load() async {
        let resp = await vm.loadWebsiteConfig(websiteId: websiteId, scope: "limit-conn")
        enable = resp?.enable ?? false
        for item in resp?.params ?? [] {
            switch item.name ?? "" {
            case "limit_conn":
                for p in item.params ?? [] {
                    // "perserver 151" / "perip 4"
                    let parts = p.split(separator: " ")
                    if parts.count == 2 {
                        if parts[0] == "perserver" { perserver = String(parts[1]) }
                        if parts[0] == "perip" { perip = String(parts[1]) }
                    }
                }
            case "limit_rate":
                // "1024k" → "1024"
                if let r = (item.params ?? []).first {
                    rate = r.hasSuffix("k") ? String(r.dropLast()) : r
                }
            default:
                break
            }
        }
        isLoading = false
    }

    /// 启用/关闭：以当前三个输入值提交（add / delete）
    private func toggle(_ on: Bool) async {
        isToggling = true
        defer { isToggling = false }
        let ok = await vm.updateWebsiteConfig(
            websiteId: websiteId,
            operate: on ? "add" : "delete",
            scope: "limit-conn",
            params: buildParams()
        )
        if ok {
            await load()
        }
    }

    /// 更新：始终 add；未启用时相当于启用并保存
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await vm.updateWebsiteConfig(
            websiteId: websiteId,
            operate: "add",
            scope: "limit-conn",
            params: buildParams()
        )
        if ok {
            await load()
        }
    }
}

// MARK: - 重定向列表

struct WebsiteRedirectView: View {
    let websiteId: Int
    @ObservedObject var vm: WebsitesViewModel

    @State private var redirects: [WebsiteRedirect] = []
    @State private var isLoading = false
    @State private var editingRedirect: WebsiteRedirect?
    @State private var showEdit = false
    @State private var sourceRedirect: WebsiteRedirect?
    @State private var showSource = false
    @State private var actionRedirect: WebsiteRedirect?
    @State private var pendingDelete: WebsiteRedirect?

    var body: some View {
        Group {
            if isLoading && redirects.isEmpty {
                ProgressView(L10n.t("加载重定向…"))
            } else if redirects.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无重定向"),
                    systemImage: "arrow.uturn.turn.right",
                    description: Text(L10n.t("点击右上角创建第一个重定向规则"))
                )
            } else {
                list
            }
        }
        .navigationTitle(L10n.t("重定向"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingRedirect = nil
                    showEdit = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task { await load() }
        .navigationDestination(isPresented: $showEdit) {
            WebsiteRedirectEditView(websiteId: websiteId, redirect: editingRedirect, vm: vm) {
                Task { await load() }
            }
        }
        .navigationDestination(isPresented: $showSource) {
            if let r = sourceRedirect {
                WebsiteRedirectSourceView(websiteId: websiteId, redirect: r, vm: vm)
            }
        }
        .sheet(isPresented: Binding(
            get: { actionRedirect != nil },
            set: { if !$0 { actionRedirect = nil } }
        )) {
            ActionBottomSheet(
                title: actionRedirect?.displayName ?? L10n.t("重定向"),
                items: [
                    ActionMenuItem(
                        title: actionRedirect?.enable == true ? L10n.t("关闭") : L10n.t("开启"),
                        icon: actionRedirect?.enable == true ? "stop.fill" : "play.fill",
                        color: actionRedirect?.enable == true ? .orange : .green
                    ) {
                        let r = actionRedirect
                        Task { if let r { await toggle(r) } }
                    },
                    ActionMenuItem(title: L10n.t("编辑"), icon: "pencil", color: .blue) {
                        editingRedirect = actionRedirect
                        showEdit = true
                    },
                    ActionMenuItem(title: L10n.t("源文"), icon: "doc.text", color: .teal) {
                        sourceRedirect = actionRedirect
                        showSource = true
                    },
                    ActionMenuItem(title: L10n.t("删除"), icon: "trash", color: .red, role: .destructive) {
                        pendingDelete = actionRedirect
                    },
                ],
                onDismiss: { actionRedirect = nil }
            )
            .presentationDetents([.height(ActionBottomSheet.height(for: 4))])
            .presentationDragIndicator(.visible)
        }
        .alert(
            L10n.t("删除"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingDelete = nil }
            Button(L10n.t("确认"), role: .destructive) {
                if let r = pendingDelete {
                    Task { await deleteRedirect(r) }
                }
                pendingDelete = nil
            }
        } message: {
            if let r = pendingDelete {
                Text(L10n.f("将对以下重定向进行 删除 操作，是否继续？\n\n%@", r.displayName))
            }
        }
    }

    private var list: some View {
        List {
            ForEach(redirects) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(r.displayName)
                            .font(.body.bold())
                        Spacer()
                        if r.enable == true {
                            Text(L10n.t("已启用"))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.1))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        } else {
                            Text(L10n.t("已停用"))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.gray.opacity(0.1))
                                .foregroundStyle(.secondary)
                                .clipShape(Capsule())
                        }
                    }
                    HStack {
                        Label(subtitle(r), systemImage: "arrow.uturn.turn.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(r.target ?? "—")
                            .font(.caption.monospaced())
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    actionRedirect = r
                }
                .swipeActions {
                    Button(role: .destructive) {
                        pendingDelete = r
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

    private func subtitle(_ r: WebsiteRedirect) -> String {
        var parts = [r.typeDisplayName, r.redirect ?? "301"]
        if r.redirectRoot == true {
            parts.append(L10n.t("重定向到首页"))
        } else if r.type == "path" {
            parts.append(r.path ?? "")
        } else if let d = r.domains?.first, !d.isEmpty {
            parts.append(d)
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        redirects = await vm.loadRedirects(websiteId: websiteId)
    }

    /// 由记录构造全量操作请求（删除/启停需带原记录字段）
    static func request(from r: WebsiteRedirect, websiteId: Int, operate: String) -> WebsiteRedirectUpdateRequest {
        WebsiteRedirectUpdateRequest(
            websiteID: r.websiteID ?? websiteId,
            operate: operate,
            enable: r.enable ?? true,
            name: r.name ?? "",
            domains: r.domains ?? [],
            keepPath: r.keepPath ?? true,
            type: r.type ?? "domain",
            redirect: r.redirect ?? "301",
            path: r.path ?? "",
            target: r.target ?? "",
            filePath: r.filePath ?? "",
            content: r.content ?? "",
            redirectRoot: r.redirectRoot ?? false
        )
    }

    private func deleteRedirect(_ r: WebsiteRedirect) async {
        let ok = await vm.operateRedirect(Self.request(from: r, websiteId: websiteId, operate: "delete"))
        if ok {
            await load()
        }
    }

    private func toggle(_ r: WebsiteRedirect) async {
        actionRedirect = nil
        let operate = (r.enable == true) ? "disable" : "enable"
        let ok = await vm.operateRedirect(Self.request(from: r, websiteId: websiteId, operate: operate))
        if ok {
            await load()
        }
    }
}

// MARK: - 重定向创建 / 编辑

struct WebsiteRedirectEditView: View {
    let websiteId: Int
    let redirect: WebsiteRedirect?
    @ObservedObject var vm: WebsitesViewModel
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type = "domain"
    @State private var method = "301"
    @State private var domains: [WebsiteDomainItem] = []
    @State private var selectedDomain = ""
    @State private var path = ""
    @State private var target = ""
    @State private var keepPath = true
    @State private var redirectRoot = false
    @State private var enable = true
    @State private var isSaving = false

    private var isEdit: Bool { redirect != nil }
    private var is404: Bool { type == "404" }

    var body: some View {
        Form {
            Section(L10n.t("基本信息")) {
                TextField(L10n.t("名称"), text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(is404 || isEdit)
                Picker(L10n.t("类型"), selection: $type) {
                    Text(L10n.t("域名")).tag("domain")
                    Text(L10n.t("路径")).tag("path")
                    Text("404").tag("404")
                }
                .pickerStyle(.segmented)
                .disabled(isEdit)
                Picker(L10n.t("方式"), selection: $method) {
                    Text("301").tag("301")
                    Text("302").tag("302")
                }
                .pickerStyle(.segmented)
            }

            Section(L10n.t("规则")) {
                if type == "domain" {
                    Picker(L10n.t("域名"), selection: $selectedDomain) {
                        Text(domains.isEmpty ? L10n.t("未获取") : L10n.t("请选择")).tag("")
                        ForEach(domains) { d in
                            Text(d.domain ?? "").tag(d.domain ?? "")
                        }
                    }
                } else if type == "path" {
                    TextField(L10n.t("路径 (例如 /ai)"), text: $path)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    Toggle(L10n.t("重定向到首页"), isOn: $redirectRoot)
                }

                if !(is404 && redirectRoot) {
                    TextField(L10n.t("目标URL地址 (http://…)"), text: $target)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if !is404 {
                    Toggle(L10n.t("保留URI参数"), isOn: $keepPath)
                }
            }

            Section(L10n.t("状态")) {
                Toggle(L10n.t("启用"), isOn: $enable)
            }
        }
        .navigationTitle(isEdit ? L10n.t("编辑重定向") : L10n.t("创建重定向"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEdit ? L10n.t("保存") : L10n.t("创建")) {
                    Task { await save() }
                }
                .disabled(!canSubmit || isSaving)
            }
        }
        .task {
            await loadDomains()
            fillFromRedirect()
        }
        .onChange(of: type) { _, newType in
            // 404 类型名称固定为 404
            if newType == "404" { name = "404" }
        }
    }

    private var canSubmit: Bool {
        if name.isEmpty { return false }
        switch type {
        case "domain":
            return !selectedDomain.isEmpty && !target.isEmpty
        case "path":
            return !path.isEmpty && !target.isEmpty
        default: // 404
            return redirectRoot || !target.isEmpty
        }
    }

    private func loadDomains() async {
        domains = await vm.loadWebsiteDomains(websiteId: websiteId)
    }

    private func fillFromRedirect() {
        guard let r = redirect else { return }
        name = r.name ?? ""
        type = r.type ?? "domain"
        method = r.redirect ?? "301"
        selectedDomain = r.domains?.first ?? ""
        path = r.path ?? ""
        target = r.target ?? ""
        keepPath = r.keepPath ?? true
        redirectRoot = r.redirectRoot ?? false
        enable = r.enable ?? true
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        var req = WebsiteRedirectUpdateRequest(
            websiteID: websiteId,
            operate: isEdit ? "edit" : "create",
            enable: enable,
            name: name,
            domains: type == "domain" ? [selectedDomain] : [],
            keepPath: is404 ? true : keepPath,
            type: type,
            redirect: method,
            path: type == "path" ? path : "",
            // 404 重定向到首页时服务端要求 target 非空，固定传 "http://"
            target: (is404 && redirectRoot) ? "http://" : target,
            filePath: redirect?.filePath ?? "",
            content: redirect?.content ?? "",
            redirectRoot: redirectRoot
        )
        if isEdit, let r = redirect {
            // 编辑时名称/类型不可改，沿用原值
            req.name = r.name ?? name
            req.type = r.type ?? type
        }
        let ok = await vm.operateRedirect(req)
        if ok {
            onDone()
            dismiss()
        }
    }
}

// MARK: - 重定向源文

/// 重定向源文（修改 nginx 配置片段）
struct WebsiteRedirectSourceView: View {
    let websiteId: Int
    let redirect: WebsiteRedirect
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
        .navigationTitle(L10n.f("源文：%@", redirect.displayName))
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
                content = redirect.content ?? ""
                originalContent = content
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await vm.saveRedirectFile(
            websiteId: websiteId,
            name: redirect.name ?? "",
            content: content
        )
        if ok {
            originalContent = content
            dismiss()
        }
    }
}

// MARK: - 密码访问

/// 密码访问：账号列表（创建/编辑/删除）+ 总开关（无账号时不可开启）
struct WebsiteAuthsView: View {
    let websiteId: Int
    @ObservedObject var vm: WebsitesViewModel

    @State private var enable = false
    @State private var items: [WebsiteAuthItem] = []
    @State private var isLoading = true
    @State private var editingItem: WebsiteAuthItem?
    @State private var showEdit = false
    @State private var pendingDelete: WebsiteAuthItem?
    @State private var isToggling = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView(L10n.t("加载中…"))
            } else {
                list
            }
        }
        .navigationTitle(L10n.t("密码访问"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingItem = nil
                    showEdit = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .navigationDestination(isPresented: $showEdit) {
            WebsiteAuthEditView(websiteId: websiteId, item: editingItem, vm: vm) {
                Task { await load() }
            }
        }
        .alert(
            L10n.t("删除"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button(L10n.t("取消"), role: .cancel) { pendingDelete = nil }
            Button(L10n.t("确认"), role: .destructive) {
                if let item = pendingDelete {
                    Task { await deleteItem(item) }
                }
                pendingDelete = nil
            }
        } message: {
            if let item = pendingDelete {
                Text(L10n.f("确定删除访问账号「%@」吗？", item.username ?? ""))
            }
        }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
    }

    private var list: some View {
        List {
            Section {
                Toggle(L10n.t("启用密码访问"), isOn: Binding(
                    get: { enable },
                    set: { on in Task { await toggle(on) } }
                ))
                .disabled(isToggling || items.isEmpty)
            } footer: {
                Text(L10n.t("开启后访问网站需输入账号密码；未创建账号时不可开启"))
            }

            Section(L10n.t("访问账号")) {
                if items.isEmpty {
                    Text(L10n.t("暂无账号"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                ForEach(items) { item in
                    Button {
                        editingItem = item
                        showEdit = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.username ?? "—")
                                    .font(.body.bold().monospaced())
                                    .foregroundStyle(.primary)
                                if let remark = item.remark, !remark.isEmpty {
                                    Text(remark)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            pendingDelete = item
                        } label: {
                            Label(L10n.t("删除"), systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        if let resp = await vm.loadAuths(websiteId: websiteId) {
            enable = resp.enable ?? false
            items = resp.items ?? []
        }
        isLoading = false
    }

    private func toggle(_ on: Bool) async {
        isToggling = true
        defer { isToggling = false }
        let ok = await vm.operateAuth(
            websiteId: websiteId,
            operate: on ? "enable" : "disable"
        )
        if ok {
            await load()
        }
    }

    private func deleteItem(_ item: WebsiteAuthItem) async {
        let ok = await vm.operateAuth(
            websiteId: websiteId,
            operate: "delete",
            username: item.username ?? "",
            remark: item.remark ?? ""
        )
        if ok {
            await load()
        }
    }
}

// MARK: - 密码访问账号创建 / 编辑

struct WebsiteAuthEditView: View {
    let websiteId: Int
    let item: WebsiteAuthItem?
    @ObservedObject var vm: WebsitesViewModel
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var remark = ""
    @State private var isSaving = false

    private var isEdit: Bool { item != nil }

    var body: some View {
        Form {
            Section(L10n.t("账号")) {
                TextField(L10n.t("用户名"), text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(isEdit)
                HStack {
                    SecureField(L10n.t("密码"), text: $password)
                    Button {
                        password = Self.randomPassword()
                    } label: {
                        Image(systemName: "dice")
                    }
                    .buttonStyle(.borderless)
                }
                TextField(L10n.t("备注"), text: $remark)
            }
        }
        .navigationTitle(isEdit ? L10n.t("编辑账号") : L10n.t("创建账号"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEdit ? L10n.t("保存") : L10n.t("创建")) {
                    Task { await save() }
                }
                .disabled(!canSubmit || isSaving)
            }
        }
        .onAppear {
            if let item {
                username = item.username ?? ""
                remark = item.remark ?? ""
            }
        }
    }

    private var canSubmit: Bool {
        !username.isEmpty && (!isEdit || !password.isEmpty)
    }

    /// 16 位随机字母数字密码
    private static func randomPassword() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<16).map { _ in chars.randomElement() ?? "x" })
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await vm.operateAuth(
            websiteId: websiteId,
            operate: isEdit ? "edit" : "create",
            username: username,
            password: password,
            remark: remark
        )
        if ok {
            onDone()
            dismiss()
        }
    }
}
