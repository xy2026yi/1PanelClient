//
//  AddNodeView.swift
//  1PanelClient
//
//  添加/编辑节点：连接信息（SSH）/ 节点信息（含分组选择）/ 数据同步 → 可用性检查 → 确认提交（异步任务进度）
//  基于网页端抓包（logs/多机管理/多机管理-节点管理-1.md、多机管理-2.md）
//  说明：密码/私钥 base64 编码传输（对齐网页端）；「使用代理」未勾选时不发送，暂未实现；
//  「导入许可证」为专业版许可流程，暂仅支持选择已有许可证
//

import SwiftUI

struct AddNodeView: View {
    let server: ServerConfig
    /// 编辑模式的节点详情（nil=添加）；rememberPassword=true 时服务端返回明文密码用于回填
    var editing: NodeDetailItem? = nil
    /// 编辑提交时随请求回传的运行状态（对齐网页端 hasLoad/isOK/node 字段）
    var currentNode: NodeCurrentItem? = nil
    /// 提交成功回调（参数为任务 taskID，调用方进入进度页）
    var onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private var isEditing: Bool { editing != nil }

    // 连接信息
    @State private var addr = ""
    @State private var port = 22
    @State private var user = "root"
    @State private var authMode = "password"
    @State private var password = ""
    @State private var privateKey = ""
    @State private var rememberPassword = false

    // 节点信息
    @State private var name = ""
    @State private var nameManuallyEdited = false
    @State private var baseDir = "/opt"
    @State private var nodePort = 9999
    @State private var isPro = false
    @State private var descriptionText = ""
    @State private var selectedGroupID = 0

    // 数据同步
    @State private var syncKeys: Set<String>

    // 分组 / 许可证
    @State private var groups: [NodeGroup] = []
    @State private var licenses: [LicenseOption] = []
    @State private var selectedLicenseID = 0

    // 状态
    @State private var isChecking = false
    @State private var testResult: NodeTestResult?
    @State private var showResultSheet = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig,
         editing: NodeDetailItem? = nil,
         currentNode: NodeCurrentItem? = nil,
         onCreate: @escaping (String) -> Void) {
        self.server = server
        self.editing = editing
        self.currentNode = currentNode
        self.onCreate = onCreate
        self.client = APIClient(server: server)

        if let e = editing {
            _addr = State(initialValue: e.addr ?? "")
            _port = State(initialValue: e.port ?? 22)
            _user = State(initialValue: e.user ?? "root")
            _authMode = State(initialValue: e.authMode ?? "password")
            _password = State(initialValue: e.password ?? "")
            _privateKey = State(initialValue: e.privateKey ?? "")
            _rememberPassword = State(initialValue: e.rememberPassword ?? false)
            _name = State(initialValue: e.name)
            _nameManuallyEdited = State(initialValue: true)  // 编辑时名称不跟随地址
            _baseDir = State(initialValue: e.baseDir ?? "/opt")
            _nodePort = State(initialValue: e.nodePort ?? 9999)
            _isPro = State(initialValue: e.isXpack ?? false)
            _descriptionText = State(initialValue: e.description ?? "")
            _selectedGroupID = State(initialValue: e.groupID ?? 0)
            _selectedLicenseID = State(initialValue: e.licenseID ?? 0)
            // 网页端编辑表单的数据同步默认 4 项全开（抓包：search 返回 SyncBackupAccounts，
            // update 提交 SyncSystemProxy,SyncBackupAccounts,SyncAlertSetting,SyncCustomApp）
            _syncKeys = State(initialValue: Set(NodeSyncOption.all.map(\.key)))
        } else {
            _syncKeys = State(initialValue: Set(NodeSyncOption.all.map(\.key)))
        }
    }

    /// 当前版本模式下可选的许可证：
    /// 社区版看 availableFreeCount、专业版看 availableXpackCount，余量为 0 则无数据
    private var availableLicenses: [LicenseOption] {
        licenses.filter { isPro ? ($0.availableXpackCount ?? 0) > 0 : ($0.availableFreeCount ?? 0) > 0 }
    }

    private var canSubmit: Bool {
        !addr.trimmingCharacters(in: .whitespaces).isEmpty
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !user.isEmpty && port > 0 && nodePort > 0
            && !baseDir.isEmpty
            && (authMode == "password" ? !password.isEmpty : !privateKey.isEmpty)
            && (!isPro || availableLicenses.indices.contains(where: { availableLicenses[$0].id == selectedLicenseID }))
    }

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                nodeInfoSection
                syncSection
            }
            .navigationTitle(isEditing ? L10n.t("编辑节点") : L10n.t("添加节点"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isChecking || isSubmitting {
                        ProgressView()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await check() }
                } label: {
                    Text(L10n.t("可用性检查"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit || isChecking || isSubmitting)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .background(.regularMaterial)
            }
            .alert(L10n.t("操作失败"), isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(L10n.t("好"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(isPresented: $showResultSheet) {
                NodeCheckResultSheet(result: testResult) {
                    Task { await submit() }
                }
                .presentationDetents([.medium])
            }
            .task {
                await loadGroupsAndLicenses()
            }
            .onChange(of: isPro) { _, _ in
                // 版本切换后可用许可证集合变化，重选首个可用项
                if !availableLicenses.indices.contains(where: { availableLicenses[$0].id == selectedLicenseID }) {
                    selectedLicenseID = availableLicenses.first?.id ?? 0
                }
            }
        }
    }

    // MARK: - 表单分区

    private var connectionSection: some View {
        Section(L10n.t("连接信息")) {
            TextField(L10n.t("主机地址"), text: $addr)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: addr) { _, newValue in
                    if !nameManuallyEdited { name = newValue }
                }
            TextField(L10n.t("端口"), value: $port, format: .number.grouping(.never))
                .keyboardType(.numberPad)
            TextField(L10n.t("用户名"), text: $user)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Picker(L10n.t("认证方式"), selection: $authMode) {
                Text(L10n.t("密码认证")).tag("password")
                Text(L10n.t("私钥认证")).tag("key")
            }
            if authMode == "password" {
                SecureField(L10n.t("密码"), text: $password)
                    .textInputAutocapitalization(.never)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("私钥"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $privateKey)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            Toggle(L10n.t("记住认证信息"), isOn: $rememberPassword)
        }
    }

    private var nodeInfoSection: some View {
        Section(L10n.t("节点信息")) {
            TextField(L10n.t("名称"), text: Binding(
                get: { name },
                set: { newValue in
                    name = newValue
                    if !newValue.isEmpty && newValue != addr { nameManuallyEdited = true }
                }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            TextField(L10n.t("安装目录"), text: $baseDir)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField(L10n.t("节点端口"), value: $nodePort, format: .number.grouping(.never))
                .keyboardType(.numberPad)
            Picker(L10n.t("版本"), selection: $isPro) {
                Text(L10n.t("社区版")).tag(false)
                Text(L10n.t("专业版")).tag(true)
            }
            if availableLicenses.isEmpty {
                Text(L10n.t("无数据"))
                    .foregroundStyle(.secondary)
            } else {
                Picker(L10n.t("许可证"), selection: $selectedLicenseID) {
                    ForEach(availableLicenses) { license in
                        Text(license.displayName).tag(license.id)
                    }
                }
            }
            if groups.isEmpty {
                // 分组接口不可用（社区版）：只读展示，沿用节点原分组
                HStack {
                    Text(L10n.t("分组"))
                    Spacer()
                    Text(groups.first(where: { $0.id == selectedGroupID })?.name
                         ?? editing?.groupBelong ?? "Default")
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker(L10n.t("分组"), selection: $selectedGroupID) {
                    ForEach(groups) { group in
                        Text(group.name ?? "#\(group.id)").tag(group.id)
                    }
                }
            }
            TextField(L10n.t("描述"), text: $descriptionText)
        }
    }

    private var syncSection: some View {
        Section {
            ForEach(NodeSyncOption.all) { option in
                Toggle(option.title, isOn: Binding(
                    get: { syncKeys.contains(option.key) },
                    set: { isOn in
                        if isOn { syncKeys.insert(option.key) } else { syncKeys.remove(option.key) }
                    }
                ))
            }
        } header: {
            Text(L10n.t("数据同步"))
        } footer: {
            Text(L10n.t("将主节点对应的配置同步到新节点。"))
        }
    }

    // MARK: - 请求构造

    private var syncListValue: String {
        NodeSyncOption.all.filter { syncKeys.contains($0.key) }.map(\.key).joined(separator: ",")
    }

    private func buildCreateRequest(taskID: String?) -> AddNodeRequest {
        AddNodeRequest(
            addr: addr.trimmingCharacters(in: .whitespaces),
            port: port,
            user: user,
            authMode: authMode,
            password: authMode == "password" ? Data(password.utf8).base64EncodedString() : "",
            privateKey: authMode == "key" ? Data(privateKey.utf8).base64EncodedString() : "",
            name: name.trimmingCharacters(in: .whitespaces),
            baseDir: baseDir,
            nodePort: nodePort,
            isXpack: isPro,
            syncList: syncListValue,
            licenseID: selectedLicenseID,
            groupID: selectedGroupID,
            rememberPassword: rememberPassword,
            description: descriptionText,
            withDockerRestart: taskID == nil ? nil : false,
            taskID: taskID
        )
    }

    /// 完整编辑：search 返回的完整对象 + 表单修改 + 运行状态一起回传（对齐网页端抓包）
    private func buildUpdateRequest(taskID: String, from e: NodeDetailItem) -> NodeUpdateRequest {
        NodeUpdateRequest(
            id: e.id,
            createdAt: e.createdAt,
            groupID: selectedGroupID,
            groupBelong: e.groupBelong,
            name: name.trimmingCharacters(in: .whitespaces),
            alias: e.alias,
            version: e.version,
            addr: addr.trimmingCharacters(in: .whitespaces),
            port: port,
            user: user,
            authMode: authMode,
            password: authMode == "password" ? Data(password.utf8).base64EncodedString() : "",
            privateKey: authMode == "key" ? Data(privateKey.utf8).base64EncodedString() : "",
            passPhrase: e.passPhrase,
            rememberPassword: rememberPassword,
            useProxy: e.useProxy,
            baseDir: baseDir,
            nodePort: nodePort,
            licenseID: selectedLicenseID,
            isXpack: isPro,
            isBound: e.isBound,
            license: e.license,
            syncList: syncListValue,
            syncStatus: e.syncStatus,
            syncMessage: e.syncMessage,
            status: e.status,
            message: e.message,
            isFavorite: e.isFavorite,
            description: descriptionText,
            hasLoad: currentNode != nil ? true : nil,
            isOK: currentNode?.isOK,
            node: currentNode,
            withDockerRestart: false,
            taskID: taskID
        )
    }

    // MARK: - 加载选项 / 可用性检查 / 提交

    private func loadGroupsAndLicenses() async {
        if let list: [NodeGroup] = try? await client.send(
            path: APIEndpoint.nodeGroupsSearch.path,
            body: NodeGroupSearchRequest(type: "node"),
            as: [NodeGroup].self
        ) {
            groups = list
            // 添加模式默认分组：标记 isDefault 的组；编辑模式保持回填的原分组
            if editing == nil, selectedGroupID == 0 {
                selectedGroupID = list.first(where: { $0.isDefault == true })?.id ?? list.first?.id ?? 0
            }
        }
        if let list: [LicenseOption] = try? await client.send(
            path: APIEndpoint.licensesOptions.path,
            method: APIEndpoint.licensesOptions.method,
            as: [LicenseOption].self
        ) {
            licenses = list
            // 编辑模式回填的许可证在当前模式下不可选时，回退到首个可用项
            if !availableLicenses.indices.contains(where: { availableLicenses[$0].id == selectedLicenseID }) {
                selectedLicenseID = availableLicenses.first?.id ?? 0
            }
        }
    }

    private func check() async {
        isChecking = true
        defer { isChecking = false }
        do {
            testResult = try await client.send(
                path: APIEndpoint.nodesTestByInfo.path,
                body: buildCreateRequest(taskID: nil),
                as: NodeTestResult.self
            )
            showResultSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func submit() async {
        showResultSheet = false
        isSubmitting = true
        defer { isSubmitting = false }
        let taskID = UUID().uuidString
        do {
            if let e = editing {
                _ = try await client.send(
                    path: APIEndpoint.nodesUpdate.path,
                    body: buildUpdateRequest(taskID: taskID, from: e),
                    as: EmptyResponse.self
                )
            } else {
                _ = try await client.send(
                    path: APIEndpoint.nodesCreate.path,
                    body: buildCreateRequest(taskID: taskID),
                    as: EmptyResponse.self
                )
            }
            dismiss()
            onCreate(taskID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 可用性检查结果弹窗

private struct NodeCheckResultSheet: View {
    let result: NodeTestResult?
    var onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    private struct CheckRow: Identifiable {
        let id = UUID()
        let title: String
        let passed: Bool
        let message: String?
    }

    private var rows: [CheckRow] {
        guard let result else { return [] }
        let serviceExist = (result.isCoreExist ?? false) || (result.isAgentExist ?? false)
            || (result.isPanelExist ?? false) || (result.isDockerExist ?? false)
        return [
            CheckRow(title: L10n.t("检查节点 SSH 连接"), passed: result.isConnOk ?? false,
                     message: result.isConnOk == true ? nil : (result.connMsg?.isEmpty == false ? result.connMsg : nil)),
            CheckRow(title: L10n.t("检查节点用户权限"), passed: result.isRoot ?? false, message: nil),
            CheckRow(title: L10n.t("检查节点许可证状态"), passed: result.isLicenseOk ?? false, message: nil),
            CheckRow(title: L10n.t("检查节点已存在服务信息"), passed: !serviceExist, message: nil),
            CheckRow(title: L10n.t("检查节点端口可达"), passed: result.isPortAvailable ?? false, message: nil),
        ]
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: row.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(row.passed ? .green : .red)
                            Text(row.title)
                                .font(.subheadline)
                            Spacer()
                        }
                        if let message = row.message {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle(L10n.t("可用性检查"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("确认")) { onConfirm() }
                        .disabled(!(result?.isConnOk ?? false))
                }
            }
        }
    }
}
