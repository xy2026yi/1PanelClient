//
//  DeviceNetworkSettingsViews.swift
//  1PanelClient
//
//  基础设置的设备配置子页：DNS / Hosts 编辑（从基础设置页跳转，
//  避免基础设置页过长）。接口：toolbox/device 的 check/dns、update/conf、
//  update/host。
//

import SwiftUI

// MARK: - 请求模型（子页自用）

private struct KeyValueRequest: Encodable {
    let key: String
    let value: String
}

// MARK: - DNS 编辑页

/// DNS 多行编辑：进入时自行加载服务器现有 DNS 作为保存基线（父页摘要可能因
/// device/base 加载失败而为空——若以空快照为基线，用户一保存就会把服务器
/// 原有 DNS 全量覆盖成输入的那几条）；每行一个，回车/失焦自动保存
/// （与基线比对有变化才提交）；「测试可用性」走 check/dns（逗号拼接）
struct DeviceDNSSettingsView: View {
    let server: ServerConfig
    /// 父页摘要快照（仅作加载完成前的初始展示，加载成功后被服务器值覆盖）
    let initial: [String]
    /// 保存成功回调（父页更新摘要）
    var onSaved: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var dnsInput: String
    @State private var baseline: [String]
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isBusy = false
    @State private var toast: String?
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private let client: APIClient

    init(server: ServerConfig, initial: [String], onSaved: @escaping ([String]) -> Void) {
        self.server = server
        self.initial = initial
        self.onSaved = onSaved
        _dnsInput = State(initialValue: initial.joined(separator: "\n"))
        _baseline = State(initialValue: initial)
        self.client = APIClient.shared(for: server)
    }

    /// 按行拆分去空
    private var dnsList: [String] {
        dnsInput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 编辑器是否可见：加载中/失败时隐藏但保留在层级里。
    /// 竖排 TextField（UIKit 支撑）在 Form 首帧布局完成后才插入会触发
    /// SwiftUI「Invalid frame dimension (negative or non-finite)」运行时警告
    /// （iOS 26.5 模拟器已实测：首帧在场/纯 push 均干净，原地换入必触发）
    private var editorVisible: Bool { !isLoading && loadError == nil }

    var body: some View {
        Form {
            Section {
                TextField(L10n.t("每行一个 DNS 地址"), text: $dnsInput, axis: .vertical)
                    .lineLimit(6...12)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    .focused($focused)
                    .onSubmit { Task { await commit() } }
                    .opacity(editorVisible ? 1 : 0)
                    .allowsHitTesting(editorVisible)
            } footer: {
                Text(L10n.t("换行输入，每行一个；失焦或回车后自动保存（全量覆盖）。"))
            }

            Section {
                Button(L10n.t("测试可用性")) {
                    Task { await testDNS() }
                }
                .disabled(isBusy || dnsList.isEmpty || !editorVisible)
            }
        }
        // loading/错误态用 overlay 表达，不结构性换入换出（见 editorVisible 注释）
        .overlay {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
            } else if let loadError {
                // 拿不到服务器基线时禁止编辑：否则空基线上保存会清空服务器 DNS
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(loadError)
                } actions: {
                    Button(L10n.t("重试")) { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle("DNS")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .keyboard) {
                HStack {
                    Spacer()
                    Button(L10n.t("完成")) { focused = false }
                }
            }
        }
        .task { await load() }
        // 离开输入框（含键盘收起）即提交；返回上级页时兜底提交一次
        .onChange(of: focused) { had, has in
            if had && !has { Task { await commit() } }
        }
        .onDisappear { Task { await commit() } }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .toastOverlay(message: $toast)
    }

    /// 拉取服务器现有 DNS 作为保存基线（与 Hosts 子页同模式）
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let base: DeviceBaseInfo = try await client.send(
                path: APIEndpoint.deviceBase.path, as: DeviceBaseInfo.self
            )
            let list = base.dns ?? []
            baseline = list
            dnsInput = list.joined(separator: "\n")
            loadError = nil
        } catch {
            // 取消（离开页面时 .task 被取消）不是失败
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
    }

    /// 有变化才提交（update/conf key=DNS 逗号拼接），成功后更新基线并回调
    private func commit() async {
        let list = dnsList
        guard !list.isEmpty, list != baseline else { return }
        // 轻校验：拦截空格/协议头/中文等随意文本直写服务器解析配置
        // （复用基础设置的主机校验：IPv4 / IPv6 / 域名）
        if let bad = list.first(where: { !PanelBasicSettingsView.isValidHostOrIP($0) }) {
            errorText = L10n.f("DNS 地址格式不正确：%@", bad)
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.deviceUpdateConf.path,
                body: KeyValueRequest(key: "DNS", value: list.joined(separator: ",")),
                as: EmptyResponse.self
            )
            baseline = list
            onSaved(list)
            toast = L10n.t("已保存")
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 测试可用性（check/dns，key=form）
    private func testDNS() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let ok: Bool = try await client.send(
                path: APIEndpoint.deviceCheckDns.path,
                body: KeyValueRequest(key: "form", value: dnsList.joined(separator: ",")),
                as: Bool.self
            )
            toast = ok ? L10n.t("DNS 可用") : L10n.t("DNS 不可用")
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Hosts 编辑页

/// Hosts 列表编辑：一行一条（IP + 域名），行尾单独删除；添加在下方展开输入行。
/// 增删均按抓包提交完整数组（update/host）
struct DeviceHostsSettingsView: View {
    let server: ServerConfig
    /// 保存成功回调（父页更新摘要）
    var onSaved: ([DeviceHostItem]) -> Void

    @State private var entries: [DeviceHostItem] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var addingHost = false
    @State private var newHostIP = ""
    @State private var newHostName = ""
    /// 待确认删除的行（行尾一键删除 = 全量覆盖提交，需先确认）
    @State private var deletingEntry: DeviceHostItem?
    @State private var isBusy = false
    @State private var toast: String?
    @State private var errorText: String?

    private let client: APIClient

    init(server: ServerConfig, onSaved: @escaping ([DeviceHostItem]) -> Void) {
        self.server = server
        self.onSaved = onSaved
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Form {
            if isLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 24) }
            } else if let loadError {
                Section {
                    ContentUnavailableView {
                        Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button(L10n.t("重试")) { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.ip)
                                    .font(.system(.subheadline, design: .monospaced).bold())
                                Text(entry.host)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                deletingEntry = entry
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .disabled(isBusy)
                        }
                    }

                    if addingHost {
                        VStack(spacing: 8) {
                            TextField(L10n.t("IP 地址"), text: $newHostIP)
                                .font(.system(.body, design: .monospaced))
                                .keyboardType(.asciiCapable)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            TextField(L10n.t("域名（可多个，空格分隔）"), text: $newHostName)
                                .font(.system(.body, design: .monospaced))
                                .keyboardType(.asciiCapable)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            HStack {
                                Button(L10n.t("取消")) {
                                    addingHost = false
                                    newHostIP = ""
                                    newHostName = ""
                                }
                                .buttonStyle(.bordered)
                                Spacer()
                                Button(L10n.t("添加")) { addHostEntry() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(newHostIP.trimmingCharacters(in: .whitespaces).isEmpty
                                              || newHostName.trimmingCharacters(in: .whitespaces).isEmpty
                                              || isBusy)
                            }
                        }
                    } else {
                        Button {
                            addingHost = true
                        } label: {
                            Label(L10n.t("添加 Hosts 记录"), systemImage: "plus.circle")
                        }
                        .disabled(isBusy)
                    }
                } footer: {
                    Text(L10n.t("增删均为全量覆盖提交，系统默认条目请谨慎移除。"))
                }
            }
        }
        .navigationTitle("Hosts")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert(L10n.t("删除 Hosts 记录"), isPresented: Binding(
            get: { deletingEntry != nil },
            set: { if !$0 { deletingEntry = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { deletingEntry = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                if let entry = deletingEntry {
                    deletingEntry = nil
                    Task { await updateHosts(entries.filter { $0 != entry }) }
                }
            }
        } message: {
            if let entry = deletingEntry {
                Text(L10n.f("确定删除 \"%@ %@\" 吗？删除为全量覆盖提交，系统默认条目请谨慎移除。", entry.ip, entry.host))
            }
        }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .toastOverlay(message: $toast)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let base: DeviceBaseInfo = try await client.send(
                path: APIEndpoint.deviceBase.path, as: DeviceBaseInfo.self
            )
            entries = base.hosts ?? []
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
    }

    /// 校验输入并提交（原数组 + 新条目）；IP 不合法保留输入供修改
    private func addHostEntry() {
        let ip = newHostIP.trimmingCharacters(in: .whitespaces)
        let host = newHostName.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty, !host.isEmpty else { return }
        guard Self.isValidHostsIP(ip) else {
            errorText = L10n.f("IP 地址格式不正确：%@", ip)
            return
        }
        addingHost = false
        newHostIP = ""
        newHostName = ""
        Task { await updateHosts(entries + [DeviceHostItem(ip: ip, host: host)]) }
    }

    /// Hosts IP 字段校验：仅接受 IPv4 / IPv6（hosts 行首是地址，不是域名）
    private static func isValidHostsIP(_ s: String) -> Bool {
        if s.contains(":") {
            // IPv6 全/压缩写法至少两个冒号；单冒号是 host:port，拒绝
            return s.filter { $0 == ":" }.count >= 2 && PanelBasicSettingsView.isValidIPv6(s)
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            (1...3).contains(part.count) && part.allSatisfy(\.isNumber)
                && (Int(part).map { (0...255).contains($0) } ?? false)
        }
    }

    /// 覆盖提交完整数组
    private func updateHosts(_ newEntries: [DeviceHostItem]) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.deviceUpdateHost.path, body: newEntries, as: EmptyResponse.self
            )
            entries = newEntries
            onSaved(newEntries)
            toast = L10n.t("已保存")
        } catch {
            errorText = error.localizedDescription
        }
    }
}
