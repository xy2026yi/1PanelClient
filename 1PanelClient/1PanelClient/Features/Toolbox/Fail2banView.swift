//
//  Fail2banView.swift
//  1PanelClient
//
//  Fail2ban 管理：基础配置 / 服务操作 / 白名单 / 黑名单 / 完整配置
//

import SwiftUI
import Combine

// MARK: - 数据模型

struct Fail2banBase: Decodable {
    let isEnable: Bool
    let isActive: Bool
    let isExist: Bool
    let version: String?
    let port: Int
    let maxRetry: Int
    let banTime: String
    let findTime: String
    let banAction: String
    let logPath: String
}

struct Fail2banUpdateRequest: Encodable {
    let key: String
    let value: String
}

struct Fail2banOperateRequest: Encodable {
    let operation: String
}

struct Fail2banSearchRequest: Encodable {
    let status: String
}

struct Fail2banIPRequest: Encodable {
    let operate: String
    let ips: [String]
}

struct Fail2banConfRequest: Encodable {
    let file: String
}

struct FileSearchRequest: Encodable {
    let path: String
    let expand: Bool
    let page: Int
    let pageSize: Int
    let showHidden: Bool
}

struct FileSearchResponse: Decodable {
    let path: String
    let items: [FileItem]?
}

struct FileItem: Decodable, Identifiable, Hashable {
    let path: String
    let name: String
    let isDir: Bool
    let isSymlink: Bool?
    let isHidden: Bool?
    let size: Int64?
    let modTime: String?
    let user: String?
    let group: String?
    let mode: String?
    let linkPath: String?

    var id: String { path }
}

// MARK: - ViewModel

@MainActor
final class Fail2banViewModel: ObservableObject {
    @Published var base: Fail2banBase?
    @Published var isLoading = true
    @Published var isOperating = false
    @Published var errorMessage: String?
    @Published var successMessage: String?

    /// 白名单 / 黑名单
    @Published var whitelist: [String] = []
    @Published var blacklist: [String] = []

    private let client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    var isInstalled: Bool { base?.isExist ?? false }

    func loadBase() async {
        isLoading = true
        defer { isLoading = false }
        do {
            base = try await client.send(path: APIEndpoint.fail2banBase.path, method: "GET", as: Fail2banBase.self)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func update(key: String, value: String) async {
        isOperating = true
        errorMessage = nil
        successMessage = nil
        defer { isOperating = false }
        let req = Fail2banUpdateRequest(key: key, value: value)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.fail2banUpdate.path, body: req, as: EmptyResponse.self)
            successMessage = "配置已更新"
            await loadBase()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func operate(_ operation: String) async {
        isOperating = true
        errorMessage = nil
        successMessage = nil
        defer { isOperating = false }
        let req = Fail2banOperateRequest(operation: operation)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.fail2banOperate.path, body: req, as: EmptyResponse.self)
            successMessage = "操作成功"
            await loadBase()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadList(status: String) async {
        let req = Fail2banSearchRequest(status: status)
        do {
            let resp: [String] = try await client.send(path: APIEndpoint.fail2banSearch.path, body: req, as: [String].self)
            if status == "ignore" { whitelist = resp }
            else { blacklist = resp }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveIPs(operate: String, ips: [String], status: String) async {
        isOperating = true
        errorMessage = nil
        successMessage = nil
        defer { isOperating = false }
        let req = Fail2banIPRequest(operate: operate, ips: ips)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.fail2banOperateSSHD.path, body: req, as: EmptyResponse.self)
            successMessage = "保存成功"
            await loadList(status: status)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Fail2ban 主视图

struct Fail2banView: View {
    @StateObject private var vm: Fail2banViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var activeSheet: Fail2banSheet?
    @State private var isServiceExpanded = false
    @State private var pendingAction: String?

    enum Fail2banSheet: Identifiable {
        case port, maxRetry, banTime, findTime, banAction, logPath
        case whitelist, blacklist, fullConfig
        var id: Self { self }
    }

    init(server: ServerConfig) {
        _vm = StateObject(wrappedValue: Fail2banViewModel(server: server))
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.base == nil {
                ProgressView("加载中…")
            } else if let base = vm.base {
                if base.isExist {
                    content(base: base)
                } else {
                    ContentUnavailableView {
                        Label("未安装 Fail2ban", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("请在服务器上安装 Fail2ban 后使用")
                    }
                }
            } else if let err = vm.errorMessage {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button("重试") { Task { await vm.loadBase() } }
                }
            }
        }
        .navigationTitle("Fail2ban")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.loadBase() }
        .task { await vm.loadBase() }
        .alert("操作成功", isPresented: Binding(
            get: { vm.successMessage != nil },
            set: { if !$0 { vm.successMessage = nil } }
        )) {
            Button("好的") { vm.successMessage = nil }
        } message: {
            Text(vm.successMessage ?? "")
        }
        .alert(
            pendingAction.map { fail2banActionDisplayName($0) } ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingAction = nil }
            Button("确认", role: .destructive) {
                let op = pendingAction
                pendingAction = nil
                if let op { Task { await vm.operate(op) } }
            }
        } message: {
            if let action = pendingAction {
                Text("将对 Fail2ban 进行 \(fail2banActionDisplayName(action)) 操作，是否继续？")
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .port:
                Fail2banNumberSheet(title: "监听 SSH 端口", value: Double(vm.base?.port ?? 22), unit: nil) { val in
                    Task { await vm.update(key: "port", value: "\(Int(val))") }
                }
            case .maxRetry:
                Fail2banNumberSheet(title: "最大重试次数", value: Double(vm.base?.maxRetry ?? 5), unit: nil) { val in
                    Task { await vm.update(key: "maxretry", value: "\(Int(val))") }
                }
            case .banTime:
                Fail2banTimeSheet(title: "禁用时间", rawValue: vm.base?.banTime ?? "600") { val in
                    Task { await vm.update(key: "bantime", value: val) }
                }
            case .findTime:
                Fail2banTimeSheet(title: "发现周期", rawValue: vm.base?.findTime ?? "300") { val in
                    Task { await vm.update(key: "findtime", value: val) }
                }
            case .banAction:
                Fail2banActionSheet(current: vm.base?.banAction ?? "ufw") { val in
                    Task { await vm.update(key: "banaction", value: val) }
                }
            case .logPath:
                Fail2banLogPathSheet(server: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""), currentPath: vm.base?.logPath ?? "") { val in
                    Task { await vm.update(key: "logpath", value: val) }
                }
            case .whitelist:
                Fail2banIPListView(title: "白名单", status: "ignore", vm: vm)
            case .blacklist:
                Fail2banIPListView(title: "黑名单", status: "banned", vm: vm)
            case .fullConfig:
                Fail2banFullConfigView(server: ServerManager.shared.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
            }
        }
    }

    @ViewBuilder
    private func content(base: Fail2banBase) -> some View {
        List {
            serviceSection(base: base)
            Section {
                HStack(spacing: 12) {
                    Button { activeSheet = .whitelist } label: {
                        Label("白名单", systemImage: "checkmark.shield")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderless)

                    Divider()
                        .frame(height: 24)

                    Button { activeSheet = .blacklist } label: {
                        Label("黑名单", systemImage: "hand.raised")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderless)
                }
                Button { activeSheet = .fullConfig } label: {
                    Label("全部配置", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
            }
            configSection(base: base)
        }
    }

    // MARK: - 服务管理

    private func serviceSection(base: Fail2banBase) -> some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fail2ban").font(.headline)
                    if let v = base.version {
                        Text("v\(v)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                StatusBadge(
                    text: base.isActive ? "运行中" : "已停止",
                    color: base.isActive ? .green : .red                )
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isServiceExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isServiceExpanded ? "chevron.up" : "chevron.down")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isServiceExpanded {
                HStack(spacing: 12) {
                    if base.isActive {
                        Button {
                            pendingAction = "stop"
                        } label: {
                            Label("停止", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    } else {
                        Button {
                            pendingAction = "start"
                        } label: {
                            Label("启动", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.green)
                    }

                    Button {
                        pendingAction = "restart"
                    } label: {
                        Label("重启", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }

                Toggle("开机自启", isOn: Binding(
                    get: { base.isEnable },
                    set: { newVal in
                        pendingAction = newVal ? "enable" : "disable"
                    }
                ))
                .disabled(vm.isOperating)
            }
        }
    }

    // MARK: - 基础配置

    private func fail2banActionDisplayName(_ action: String) -> String {
        switch action {
        case "stop":    return "停止"
        case "start":   return "启动"
        case "restart": return "重启"
        case "enable":  return "开启自启"
        case "disable": return "关闭自启"
        default:        return action
        }
    }

    private func configSection(base: Fail2banBase) -> some View {
        Section {
            configRow(title: "监听 SSH 端口", value: "\(base.port)") { activeSheet = .port }
            configRow(title: "最大重试次数", value: "\(base.maxRetry)") { activeSheet = .maxRetry }
            configRow(title: "禁用时间", value: base.banTime) { activeSheet = .banTime }
            configRow(title: "发现周期", value: base.findTime) { activeSheet = .findTime }
            configRow(title: "禁用方式", value: base.banAction) { activeSheet = .banAction }
            configRow(title: "日志路径", value: base.logPath) { activeSheet = .logPath }
        } header: {
            SectionLabel(title: "基础配置", systemImage: "slider.horizontal.3")
        }
    }

    private func configRow(title: String, value: String, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 数字输入 Sheet（端口 / 重试次数）

struct Fail2banNumberSheet: View {
    let title: String
    let value: Double
    let unit: String?
    let onConfirm: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var input: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(title) {
                    TextField("", text: $input)
                        .keyboardType(.numberPad)
                        .font(.system(.body, design: .monospaced))
                        .onAppear { input = "\(Int(value))" }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认") {
                        if let v = Double(input) { onConfirm(v) }
                        dismiss()
                    }
                    .disabled(input.isEmpty)
                }
            }
        }
        .presentationDetents([.height(200)])
    }
}

// MARK: - 时间输入 Sheet（禁用时间 / 发现周期）

struct Fail2banTimeSheet: View {
    let title: String
    let rawValue: String
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amount: String = ""
    @State private var unit: String = ""

    private let units = ["秒": "s", "分钟": "m", "小时": "h", "天": "d", "年": "y"]

    var body: some View {
        NavigationStack {
            Form {
                Section(title) {
                    HStack {
                        TextField("数值", text: $amount)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                        Picker("单位", selection: $unit) {
                            ForEach(Array(units.keys), id: \.self) { label in
                                Text(label).tag(units[label]!)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    .onAppear { parseRaw() }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认") {
                        onConfirm("\(amount)\(unit)")
                        dismiss()
                    }
                    .disabled(amount.isEmpty)
                }
            }
        }
        .presentationDetents([.height(250)])
    }

    private func parseRaw() {
        let chars = rawValue
        var numPart = ""
        var unitPart = "s"
        for ch in chars {
            if ch.isNumber { numPart.append(ch) }
            else if !numPart.isEmpty {
                unitPart = String(ch)
                break
            }
        }
        if numPart.isEmpty { numPart = rawValue }
        amount = numPart
        unit = unitPart
    }
}

// MARK: - 禁用方式 Sheet

struct Fail2banActionSheet: View {
    let current: String
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection = ""

    private let actions: [(value: String, label: String, desc: String)] = [
        ("iptables-allports", "iptables-allports", "通过 iptables 来禁用指定的 IP 地址(所有端口)"),
        ("iptables-multiport", "iptables-multiport", "通过 iptables 来禁用指定的 IP 地址"),
        ("firewallcmd-ipset", "firewallcmd-ipset", "通过 firewallcmd ipset 来禁用指定的 IP 地址"),
        ("ufw", "ufw", "通过 ufw 来禁用指定的 IP 地址"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                ForEach(actions, id: \.value) { action in
                    Button {
                        selection = action.value
                        onConfirm(action.value)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(action.label).foregroundStyle(.primary)
                                Text(action.desc).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if (selection.isEmpty ? current : selection) == action.value {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("禁用方式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - 日志路径 Sheet（手动输入 + 文件浏览）

struct Fail2banLogPathSheet: View {
    let server: ServerConfig
    let currentPath: String
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var inputPath = ""
    @State private var showFileBrowser = false

    var body: some View {
        NavigationStack {
            Form {
                Section("日志路径") {
                    TextField("/var/log/auth.log", text: $inputPath)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                        .onAppear { inputPath = currentPath }
                }
                Section {
                    Button {
                        showFileBrowser = true
                    } label: {
                        Label("从服务器选择文件", systemImage: "folder")
                    }
                }
            }
            .navigationTitle("日志路径")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认") {
                        onConfirm(inputPath)
                        dismiss()
                    }
                    .disabled(inputPath.isEmpty)
                }
            }
            .sheet(isPresented: $showFileBrowser) {
                FileBrowserView(server: server) { path in
                    inputPath = path
                }
            }
        }
    }
}

// MARK: - 文件浏览器

struct FileBrowserView: View {
    let server: ServerConfig
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentPath = "/"
    @State private var items: [FileItem] = []
    @State private var isLoading = false
    @State private var navigationStack: [String] = ["/"]

    private let client: APIClient

    init(server: ServerConfig, onPick: @escaping (String) -> Void) {
        self.server = server
        self.onPick = onPick
        self.client = APIClient(server: server)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else {
                    List(items) { item in
                        Button {
                            if item.isDir {
                                navigationStack.append(item.path)
                                Task { await loadDir(item.path) }
                            } else {
                                onPick(item.path)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Image(systemName: item.isDir ? "folder" : "doc")
                                    .foregroundStyle(item.isDir ? .blue : .secondary)
                                Text(item.name)
                                Spacer()
                                if !item.isDir {
                                    Image(systemName: "checkmark.circle")
                                        .foregroundStyle(.tertiary)
                                        .font(.caption)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(currentPath == "/" ? "根目录" : (currentPath as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                if navigationStack.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            navigationStack.removeLast()
                            currentPath = navigationStack.last ?? "/"
                            Task { await loadDir(currentPath) }
                        } label: {
                            Label("返回", systemImage: "chevron.left")
                        }
                    }
                }
            }
        }
        .task { await loadDir("/") }
    }

    private func loadDir(_ path: String) async {
        isLoading = true
        currentPath = path
        let req = FileSearchRequest(path: path, expand: true, page: 1, pageSize: 300, showHidden: true)
        do {
            let resp: FileSearchResponse = try await client.send(path: APIEndpoint.filesSearch.path, body: req, as: FileSearchResponse.self)
            items = (resp.items ?? []).sorted { a, b in
                if a.isDir != b.isDir { return a.isDir && !b.isDir }
                return a.name < b.name
            }
        } catch {
            items = []
        }
        isLoading = false
    }
}

// MARK: - 白名单 / 黑名单视图

struct Fail2banIPListView: View {
    let title: String
    let status: String
    @ObservedObject var vm: Fail2banViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var newIP = ""

    private var isWhitelist: Bool { status == "ignore" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("输入 IP 或 IP 段", text: $newIP)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.body, design: .monospaced))
                        Button {
                            guard !newIP.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            let ips = isWhitelist ? vm.whitelist : vm.blacklist
                            Task {
                                await vm.saveIPs(
                                    operate: isWhitelist ? "ignore" : "banned",
                                    ips: ips + [newIP.trimmingCharacters(in: .whitespaces)],
                                    status: status
                                )
                                newIP = ""
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                        }
                    }
                }
                Section("\(isWhitelist ? "白名单" : "黑名单")列表") {
                    let ips = isWhitelist ? vm.whitelist : vm.blacklist
                    if ips.isEmpty {
                        Text("暂无数据").foregroundStyle(.secondary)
                    } else {
                        ForEach(ips, id: \.self) { ip in
                            HStack {
                                Image(systemName: isWhitelist ? "checkmark.shield" : "hand.raised")
                                    .foregroundStyle(isWhitelist ? .green : .red)
                                Text(ip).font(.system(.body, design: .monospaced))
                                Spacer()
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    let remaining = ips.filter { $0 != ip }
                                    Task {
                                        await vm.saveIPs(
                                            operate: isWhitelist ? "ignore" : "banned",
                                            ips: remaining,
                                            status: status
                                        )
                                    }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await vm.loadList(status: status) }
        }
    }
}

// MARK: - 完整配置编辑

struct Fail2banFullConfigView: View {
    let server: ServerConfig

    @Environment(\.dismiss) private var dismiss
    @State private var configText = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient(server: server)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("加载配置…")
                } else {
                    TextEditor(text: $configText)
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("全部配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        Task { await save() }
                    }
                    .disabled(isLoading || isSaving)
                }
            }
            .alert("操作成功", isPresented: Binding(
                get: { successMessage != nil },
                set: { if !$0 { successMessage = nil } }
            )) {
                Button("好的") { successMessage = nil }
            } message: {
                Text(successMessage ?? "")
            }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        do {
            configText = try await client.send(path: APIEndpoint.fail2banLoadConf.path, method: "GET", as: String.self)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        isSaving = true
        let req = Fail2banConfRequest(file: configText)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.fail2banUpdateByConf.path, body: req, as: EmptyResponse.self)
            successMessage = "配置已保存"
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
