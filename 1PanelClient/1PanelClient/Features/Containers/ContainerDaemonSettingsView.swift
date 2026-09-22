//
//  ContainerDaemonSettingsView.swift
//  1PanelClient
//
//  Docker daemon 配置（容器状态抽屉「设置」进入）：
//  读 GET /containers/daemonjson + POST /settings/search（dockerSockPath）；
//  写 daemonjson/update {key,value}（镜像加速/私有仓库/iptables/LiveRestore/
//  Cgroup Driver/IPv6 关闭）、ipv6option/update、logoption/update、
//  settings/update（DockerSockPath）。抓包 2026-09-22。
//  所有 daemon 项改动均需输入「立即重启」确认（重启后生效）。
//

import SwiftUI

// MARK: - 模型

/// GET /api/v2/containers/daemonjson
nonisolated struct DockerDaemonJSON: Decodable {
    var isSwarm: Bool?
    var version: String?
    var registryMirrors: [String]?
    var insecureRegistries: [String]?
    var liveRestore: Bool?
    var iptables: Bool?
    var cgroupDriver: String?
    var ipv6: Bool?
    var fixedCidrV6: String?
    var ip6Tables: Bool?
    var experimental: Bool?
    var logMaxSize: String?
    var logMaxFile: String?
}

/// daemon.json 单项更新 {key,value}（也用于 IPv6 / 日志切割的「关闭」）
nonisolated struct DockerDaemonKeyUpdateRequest: Encodable {
    let key: String
    let value: String
}

/// POST /containers/ipv6option/update（开启 IPv6）
nonisolated struct DockerIPv6OptionRequest: Encodable {
    let fixedCidrV6: String
    let ip6Tables: Bool
    let experimental: Bool
}

/// POST /containers/logoption/update（开启日志切割；logMaxSize 形如 "10m"）
nonisolated struct DockerLogOptionRequest: Encodable {
    let logMaxSize: String
    let logMaxFile: String
}

// MARK: - 设置主页

struct ContainerDaemonSettingsView: View {
    let server: ServerConfig

    @Environment(\.dismiss) private var dismiss
    @State private var daemon: DockerDaemonJSON?
    @State private var sockPath = ""
    /// 加载时的 Socket 路径（脏检查控制保存按钮）
    @State private var loadedSockPath = ""
    @State private var isLoading = true
    @State private var loadError: String?

    /// 输入「立即重启」的确认操作（Daemon 配置修改）
    @State private var pendingOp: DaemonPendingOp?
    /// Socket 路径保存确认（是否继续，无输入确认）
    @State private var showSockConfirm = false
    @State private var showSockPicker = false
    @State private var isOperating = false
    @State private var toast: String?
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    private var serverLogOn: Bool { !(daemon?.logMaxSize ?? "").isEmpty }

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
            } else if let daemon {
                repoSection
                toggleLinkSection
                basicSection(daemon)
                sockSection
            }
        }
        .navigationTitle(L10n.t("设置"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let v = daemon?.version, !v.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("v\(v)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        // 「立即重启」输入确认（daemon 项共用）
        .sheet(item: $pendingOp) { op in
            TextInputConfirmSheet(
                title: op.title,
                message: op.message,
                expectedText: L10n.t("立即重启"),
                confirmTitle: L10n.t("确认")) {
                await op.action()
            } options: {
                EmptyView()
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showSockPicker) {
            DirectoryPickerSheet(client: client, fileExtensions: ["sock", "socket"]) { path in
                // 文件浏览器回填固定加 unix:// 前缀
                sockPath = "unix://\(path)"
            }
        }
        .alert(L10n.t("Socket 路径"), isPresented: $showSockConfirm) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("确认"), role: .destructive) {
                Task { await saveSockPath() }
            }
        } message: {
            Text(L10n.t("修改配置后需要重启 Docker 服务生效\n保存设置 Socket 路径可能导致 Docker 服务不可用，是否继续？"))
        }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .toastOverlay(message: $toast)
    }

    // MARK: 数据加载

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let daemonResult = try await client.send(
                path: APIEndpoint.containersDaemonjson.path,
                method: APIEndpoint.containersDaemonjson.method,
                as: DockerDaemonJSON.self)
            async let settingsResult = try? await client.send(
                path: APIEndpoint.settingsSearchPanel.path, as: SettingInfo.self)
            let d = try await daemonResult
            let s = await settingsResult
            daemon = d
            loadError = nil
            sockPath = s?.dockerSockPath ?? ""
            loadedSockPath = sockPath
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
    }

    /// 镜像加速 / 私有仓库（形态 7.1：推入多行编辑页，一行一个，提交逗号拼接）
    private var repoSection: some View {
        Section {
            NavigationLink {
                DaemonListEditorPage(
                    title: L10n.t("镜像加速"), updateKey: "Mirrors",
                    placeholder: "https://docker.xuanyuan.me",
                    initialLines: daemon?.registryMirrors ?? [],
                    footerText: L10n.t("一行一个镜像加速地址，保存时以逗号拼接提交"),
                    client: client) {
                    Task { await load() }
                }
            } label: {
                LabeledContent(L10n.t("镜像加速"), value: countText(daemon?.registryMirrors))
            }
            NavigationLink {
                DaemonListEditorPage(
                    title: L10n.t("私有仓库"), updateKey: "Registries",
                    placeholder: "192.168.50.20:8088",
                    initialLines: daemon?.insecureRegistries ?? [],
                    footerText: L10n.t("一行一个仓库地址（主机:端口），保存时以逗号拼接提交"),
                    client: client) {
                    Task { await load() }
                }
            } label: {
                LabeledContent(L10n.t("私有仓库"), value: countText(daemon?.insecureRegistries))
            }
        } header: {
            Text(L10n.t("镜像与仓库"))
        }
    }

    private func countText(_ list: [String]?) -> String {
        let n = list?.count ?? 0
        return n == 0 ? L10n.t("未设置") : L10n.f("%ld 条", n)
    }

    /// IPv6 / 日志切割：状态行 → 跳转独立配置页（右上角保存）
    private var toggleLinkSection: some View {
        Section {
            NavigationLink {
                DaemonIPv6Page(
                    client: client,
                    initialEnabled: daemon?.ipv6 == true,
                    initialCidr: daemon?.fixedCidrV6 ?? "",
                    initialIP6Tables: daemon?.ip6Tables ?? false,
                    initialExperimental: daemon?.experimental ?? true) {
                    Task { await load() }
                }
            } label: {
                LabeledContent("IPv6", value: daemon?.ipv6 == true
                               ? L10n.t("已启用") : L10n.t("未启用"))
            }
            NavigationLink {
                DaemonLogPage(
                    client: client,
                    initialEnabled: serverLogOn,
                    initialSize: logInitial.size, initialUnit: logInitial.unit,
                    initialFiles: logInitial.files) {
                    Task { await load() }
                }
            } label: {
                LabeledContent(L10n.t("日志切割"), value: serverLogOn
                               ? "\(logInitial.size)\(logUnitLabel(logInitial.unit)) · \(logInitial.files)\(L10n.t("份"))"
                               : L10n.t("未启用"))
            }
        }
    }

    private func logUnitLabel(_ u: String) -> String {
        ["k": "KB", "m": "MB", "g": "GB"][u] ?? u.uppercased()
    }

    /// 服务端 logMaxSize/logMaxFile → 页面初值（"10m"/"3" → (10, m, 3)）
    private var logInitial: (size: String, unit: String, files: String) {
        let raw = daemon?.logMaxSize ?? ""
        var size = "10", unit = "m"
        if !raw.isEmpty {
            let u = String(raw.suffix(1)).lowercased()
            if ["k", "m", "g"].contains(u) {
                unit = u
                size = String(raw.dropLast(1))
            } else {
                size = raw
            }
        }
        let files = (daemon?.logMaxFile ?? "").isEmpty ? "3" : (daemon?.logMaxFile ?? "3")
        return (size, unit, files)
    }

    /// iptables / Live restore / Cgroup Driver
    private func basicSection(_ daemon: DockerDaemonJSON) -> some View {
        Section {
            Toggle("iptables", isOn: toggleBinding(
                current: daemon.iptables ?? true,
                title: { on in on ? L10n.t("配置修改") : L10n.t("关闭 iptables") },
                extraMessage: { on in
                    // 关闭有额外后果提示（对齐网页端「关闭 iptables」文案）
                    on ? nil : L10n.t("关闭 iptables 会导致容器无法与外部网络通信。")
                },
                key: "IPtables"))

            Toggle(L10n.t("Live restore"), isOn: toggleBinding(
                current: daemon.liveRestore ?? false,
                title: { _ in L10n.t("配置修改") },
                key: "LiveRestore"))

            OutlinedPicker(label: "Cgroup Driver", options: ["cgroupfs", "systemd"],
                           selection: Binding(
                               get: { daemon.cgroupDriver ?? "cgroupfs" },
                               set: { newValue in
                                   guard newValue != (daemon.cgroupDriver ?? "cgroupfs") else { return }
                                   pendingOp = DaemonPendingOp(
                                       title: L10n.t("配置修改"),
                                       message: standardDaemonMessage) {
                                       if await post(DockerDaemonKeyUpdateRequest(key: "Driver", value: newValue),
                                                     path: APIEndpoint.containersDaemonjsonUpdate.path) {
                                           toast = L10n.t("已保存，重启 Docker 后生效")
                                           await load()
                                       }
                                   }
                               }))
        } header: {
            Text(L10n.t("基础配置"))
        }
    }

    /// 服务端态驱动的 Toggle：切换时先弹「立即重启」确认（daemonjson/update
    /// enable/disable），取消/失败保持服务端态（get 恒读服务端值，无需本地回滚）
    private func toggleBinding(
        current: Bool,
        title: @escaping (Bool) -> String,
        extraMessage: @escaping (Bool) -> String? = { _ in nil },
        key: String
    ) -> Binding<Bool> {
        Binding<Bool>(
            get: { current },
            set: { on in
                var message = standardDaemonMessage
                if let extra = extraMessage(on) {
                    message = extra + "\n" + message
                }
                let value = on ? "enable" : "disable"
                pendingOp = DaemonPendingOp(title: title(on), message: message) {
                    if await post(DockerDaemonKeyUpdateRequest(key: key, value: value),
                                  path: APIEndpoint.containersDaemonjsonUpdate.path) {
                        toast = L10n.t("已保存，重启 Docker 后生效")
                        await load()
                    }
                }
            })
    }

    /// Socket 路径：输入框（文件浏览器回填加 unix:// 前缀）+ 保存（普通确认）
    private var sockSection: some View {
        Section {
            OutlinedShape(label: L10n.t("Socket路径"), isFocused: false,
                          hasValue: !sockPath.isEmpty,
                          trailing: {
                Button {
                    showSockPicker = true
                } label: {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.t("选择文件"))
            }) {
                TextField("unix:///var/run/docker.sock", text: $sockPath)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Button {
                showSockConfirm = true
            } label: {
                Label(L10n.t("保存"), systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .listRowBackground(Color.clear)
            .disabled(sockPath == loadedSockPath || isOperating)
        } header: {
            Text(L10n.t("Socket路径"))
        } footer: {
            Text(L10n.t("面板访问 Docker 的 Socket 地址；可从文件浏览器选择 sock 文件自动回填"))
        }
    }

    private func saveSockPath() async {
        isOperating = true
        defer { isOperating = false }
        let value = sockPath.trimmingCharacters(in: .whitespaces)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.settingsUpdate.path,
                body: CoreSettingUpdateRequest(key: "DockerSockPath", value: value),
                as: EmptyResponse.self)
            loadedSockPath = sockPath
            toast = L10n.t("已保存")
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    // MARK: 提交

    private var standardDaemonMessage: String {
        L10n.t("修改配置后需要重启 Docker 服务生效\n如果确认操作，请手动输入「立即重启」")
    }

    @discardableResult
    private func post<Req: Encodable>(_ body: Req, path: String) async -> Bool {
        isOperating = true
        defer { isOperating = false }
        do {
            let _: EmptyResponse = try await client.send(path: path, body: body, as: EmptyResponse.self)
            return true
        } catch {
            guard !APIError.isCancellation(error) else { return false }
            errorMessage = error.localizedDescription
            showError = true
            return false
        }
    }
}

// MARK: - 待确认操作（输入「立即重启」）

private struct DaemonPendingOp: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: () async -> Void
}

// MARK: - 形态 7.1：镜像加速 / 私有仓库列表编辑页

/// 一行一个地址的多行编辑：保存时「立即重启」输入确认 → 逗号拼接提交 daemonjson/update
private struct DaemonListEditorPage: View {
    let title: String
    let updateKey: String
    let placeholder: String
    let initialLines: [String]
    let footerText: String
    let client: APIClient
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loadedText = ""
    @State private var showConfirm = false
    @State private var isSaving = false

    var body: some View {
        Form {
            Section {
                OutlinedMultiLineField(label: title, prompt: placeholder,
                                       lines: 6, text: $text)
            } footer: {
                Text(footerText)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(isSaving || text == loadedText)
            }
        }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { errorMessageText != nil },
            set: { if !$0 { errorMessageText = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessageText ?? "")
        }
        .onAppear {
            if loadedText.isEmpty {
                text = initialLines.joined(separator: "\n")
                loadedText = text
            }
        }
        .sheet(isPresented: $showConfirm) {
            TextInputConfirmSheet(
                title: L10n.t("配置修改"),
                message: L10n.t("修改配置后需要重启 Docker 服务生效\n如果确认操作，请手动输入「立即重启」"),
                expectedText: L10n.t("立即重启"),
                confirmTitle: L10n.t("确认")) {
                await submit()
            } options: {
                EmptyView()
            }
            .presentationDetents([.medium])
        }
    }

    private var lines: [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func save() async {
        showConfirm = true
    }

    private func submit() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersDaemonjsonUpdate.path,
                body: DockerDaemonKeyUpdateRequest(key: updateKey, value: lines.joined(separator: ",")),
                as: EmptyResponse.self)
            loadedText = text
            dismiss()
            onSaved()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            // sheet 已关闭，错误经延迟 alert 提示（sheet 期间 alert 会被遮挡）
            try? await Task.sleep(nanoseconds: 400_000_000)
            errorMessageText = error.localizedDescription
            showError = true
        }
    }

    @State private var errorMessageText: String?
    @State private var showError = false
}


// MARK: - IPv6 配置页（跳转进入，右上角保存）

/// IPv6：开关 + 子网/ip6tables/experimental；保存时「立即重启」确认——
/// 开启走 ipv6option/update，关闭（服务端已开启时）走 daemonjson/update disable
private struct DaemonIPv6Page: View {
    let client: APIClient
    let initialEnabled: Bool
    let initialCidr: String
    let initialIP6Tables: Bool
    let initialExperimental: Bool
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var cidr = ""
    @State private var ip6Tables = false
    @State private var experimental = true
    @State private var showConfirm = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var didInit = false

    private var isDirty: Bool {
        enabled != initialEnabled || cidr != initialCidr
            || ip6Tables != initialIP6Tables || experimental != initialExperimental
    }

    var body: some View {
        Form {
            Section {
                Toggle(L10n.t("启用"), isOn: $enabled)
                if enabled {
                    OutlinedTextField(label: L10n.t("子网"), prompt: "fe81::0/80",
                                      text: $cidr, keyboardType: .URL)
                    Toggle("ip6tables", isOn: $ip6Tables)
                    Toggle("experimental", isOn: $experimental)
                }
            } footer: {
                Text(L10n.t("开启后需填写 IPv6 子网并保存；关闭将从 daemon.json 移除 IPv6 配置"))
            }
        }
        .navigationTitle("IPv6")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    save()
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(isSaving || !isDirty)
            }
        }
        .onAppear {
            if !didInit {
                didInit = true
                enabled = initialEnabled
                cidr = initialCidr
                ip6Tables = initialIP6Tables
                experimental = initialExperimental
            }
        }
        .sheet(isPresented: $showConfirm) {
            TextInputConfirmSheet(
                title: L10n.t("配置修改"),
                message: L10n.t("修改配置后需要重启 Docker 服务生效\n如果确认操作，请手动输入「立即重启」"),
                expectedText: L10n.t("立即重启"),
                confirmTitle: L10n.t("确认")) {
                await submit()
            } options: {
                EmptyView()
            }
            .presentationDetents([.medium])
        }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        if enabled {
            let trimmed = cidr.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                errorMessage = L10n.t("请填写子网")
                showError = true
                return
            }
        }
        showConfirm = true
    }

    private func submit() async {
        isSaving = true
        defer { isSaving = false }
        do {
            if enabled {
                let _: EmptyResponse = try await client.send(
                    path: APIEndpoint.containersIpv6OptionUpdate.path,
                    body: DockerIPv6OptionRequest(
                        fixedCidrV6: cidr.trimmingCharacters(in: .whitespaces),
                        ip6Tables: ip6Tables, experimental: experimental),
                    as: EmptyResponse.self)
            } else {
                // 服务端本就未开启时关闭无变化（脏检查已拦），此处仅覆盖关闭路径
                let _: EmptyResponse = try await client.send(
                    path: APIEndpoint.containersDaemonjsonUpdate.path,
                    body: DockerDaemonKeyUpdateRequest(key: "Ipv6", value: "disable"),
                    as: EmptyResponse.self)
            }
            dismiss()
            onSaved()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - 日志切割配置页（跳转进入，右上角保存）

/// 日志切割：开关 + 文件大小/单位/保留份数；保存「立即重启」确认——
/// 开启走 logoption/update，关闭（服务端已开启时）走 {key:LogOption,value:disable}
private struct DaemonLogPage: View {
    let client: APIClient
    let initialEnabled: Bool
    let initialSize: String
    let initialUnit: String
    let initialFiles: String
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var sizeText = "10"
    @State private var unit = "m"
    @State private var filesText = "3"
    @State private var showConfirm = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var didInit = false

    private var isDirty: Bool {
        enabled != initialEnabled || sizeText != initialSize
            || unit != initialUnit || filesText != initialFiles
    }

    var body: some View {
        Form {
            Section {
                Toggle(L10n.t("启用"), isOn: $enabled)
                if enabled {
                    OutlinedUnitField(label: L10n.t("文件大小"), unit: "",
                                      text: $sizeText, range: 1...1024)
                    OutlinedPicker(label: L10n.t("文件单位"), options: ["k", "m", "g"],
                                   selection: $unit,
                                   optionLabels: ["k": "KB", "m": "MB", "g": "GB"])
                    OutlinedUnitField(label: L10n.t("保留份数"), unit: L10n.t("份"),
                                      text: $filesText, range: 1...100)
                }
            } footer: {
                Text(L10n.t("当前配置只会影响新创建的容器；已经创建的容器需要重新创建使配置生效；注意，重新创建容器可能会导致数据丢失。如果你的容器中有重要数据，确保在执行重建操作之前进行备份。"))
            }
        }
        .navigationTitle(L10n.t("日志切割"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    save()
                } label: {
                    if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                }
                .disabled(isSaving || !isDirty)
            }
        }
        .onAppear {
            if !didInit {
                didInit = true
                enabled = initialEnabled
                sizeText = initialSize
                unit = initialUnit
                filesText = initialFiles
            }
        }
        .sheet(isPresented: $showConfirm) {
            TextInputConfirmSheet(
                title: L10n.t("配置修改"),
                message: L10n.t("修改配置后需要重启 Docker 服务生效\n如果确认操作，请手动输入「立即重启」"),
                expectedText: L10n.t("立即重启"),
                confirmTitle: L10n.t("确认")) {
                await submit()
            } options: {
                EmptyView()
            }
            .presentationDetents([.medium])
        }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        if enabled {
            guard (Int(sizeText) ?? 0) >= 1, (Int(filesText) ?? 0) >= 1 else {
                errorMessage = L10n.t("请填写文件大小与保留份数")
                showError = true
                return
            }
        }
        showConfirm = true
    }

    private func submit() async {
        isSaving = true
        defer { isSaving = false }
        do {
            if enabled {
                let _: EmptyResponse = try await client.send(
                    path: APIEndpoint.containersLogOptionUpdate.path,
                    body: DockerLogOptionRequest(
                        logMaxSize: "\(sizeText)\(unit)",
                        logMaxFile: filesText),
                    as: EmptyResponse.self)
            } else {
                let _: EmptyResponse = try await client.send(
                    path: APIEndpoint.containersLogOptionUpdate.path,
                    body: DockerDaemonKeyUpdateRequest(key: "LogOption", value: "disable"),
                    as: EmptyResponse.self)
            }
            dismiss()
            onSaved()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
