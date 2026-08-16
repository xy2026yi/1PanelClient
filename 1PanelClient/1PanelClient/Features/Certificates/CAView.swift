//
//  CAView.swift
//  1PanelClient
//
//  自签证书（CA 机构）管理：列表 / 详情 / 创建 / 签发证书
//  基于 doc/ssl证书-0628-3.md
//

import SwiftUI

// MARK: - CA 列表

struct CAListView: View {
    @ObservedObject var vm: CertificatesViewModel

    @State private var accounts: [CertificateAuthority] = []
    @State private var isLoading = false
    @State private var showCreate = false
    @State private var pendingDelete: CertificateAuthority?

    var body: some View {
        Group {
            if isLoading && accounts.isEmpty {
                ProgressView("加载中…")
            } else if accounts.isEmpty {
                ContentUnavailableView(
                    "暂无自签证书机构",
                    systemImage: "certificate",
                    description: Text("点击右下角按钮创建第一个 CA 机构")
                )
            } else {
                accountList
            }
        }
        .navigationTitle("自签证书")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            FloatingActionButton(action: {
                showCreate = true
            })
            .accessibilityLabel("创建机构")
        }
        .navigationDestination(isPresented: $showCreate) {
            CreateCAView(vm: vm) {
                Task { await load() }
            }
        }
        .alert("删除", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) {
                pendingDelete = nil
            }
            Button("确认", role: .destructive) {
                if let account = pendingDelete {
                    Task {
                        if await vm.deleteCA(id: account.id) {
                            await load()
                        }
                    }
                }
            }
        } message: {
            if let account = pendingDelete {
                Text("将对以下证书颁发机构进行 删除 操作，是否继续？\n\n\(account.name)")
            }
        }
        .task { await load() }
    }

    private var accountList: some View {
        List {
            ForEach(accounts) { account in
                NavigationLink {
                    CADetailView(ca: account, vm: vm) {
                        Task { await load() }
                    }
                } label: {
                    CARow(ca: account)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = account
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await load()
        }
    }

    private func load() async {
        isLoading = true; defer { isLoading = false }
        accounts = await vm.loadCAs()
    }
}

struct CARow: View {
    let ca: CertificateAuthority

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(
                systemName: "certificate",
                color: .purple,
                cornerRadius: 12
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(ca.name.isEmpty ? "（未命名）" : ca.name)
                    .font(.body.bold())
                    .lineLimit(1)
                Text(SSLKeyType(rawValue: ca.keyType)?.displayName ?? ca.keyType)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - CA 详情

struct CADetailView: View {
    let ca: CertificateAuthority
    @ObservedObject var vm: CertificatesViewModel
    var onDeleted: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var detail: CertificateAuthority?
    @State private var tab: CADetailTab = .info
    @State private var showIssue = false
    @State private var pendingDelete = false

    private enum CADetailTab: String, CaseIterable, Identifiable {
        case info = "机构详情"
        case cert = "证书"
        case privKey = "私钥"
        var id: String { rawValue }
    }

    var body: some View {
        List {
            Section {
                Picker("", selection: $tab) {
                    ForEach(CADetailTab.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }

            switch tab {
            case .info:    infoSection
            case .cert:    pemSection(title: "证书", content: (detail ?? ca).csr)
            case .privKey: pemSection(title: "私钥", content: (detail ?? ca).privateKey)
            }
        }
        .navigationTitle((detail ?? ca).name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showIssue = true
                    } label: {
                        Label("签发证书", systemImage: "doc.badge.plus")
                    }
                    Divider()
                    Button(role: .destructive) {
                        pendingDelete = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .navigationDestination(isPresented: $showIssue) {
            IssueCertificateView(ca: detail ?? ca, vm: vm)
        }
        .alert("删除", isPresented: $pendingDelete) {
            Button("取消", role: .cancel) {}
            Button("确认", role: .destructive) {
                Task { await doDelete() }
            }
        } message: {
            Text("将对以下证书颁发机构进行 删除 操作，是否继续？\n\n\((detail ?? ca).name)")
        }
        .task { await loadDetail() }
    }

    private var infoSection: some View {
        let d = detail ?? ca
        return Section {
            InfoRow("名称", value: d.name)
            InfoRow("证书主体名称(CN)", value: d.commonName ?? "—")
            InfoRow("颁发组织", value: d.organization ?? "—")
            if let unit = d.organizationUint, !unit.isEmpty {
                InfoRow("部门", value: unit)
            }
            if let country = d.country, !country.isEmpty {
                InfoRow("国家代号", value: country)
            }
            if let province = d.province, !province.isEmpty {
                InfoRow("省份", value: province)
            }
            if let city = d.city, !city.isEmpty {
                InfoRow("城市", value: city)
            }
            InfoRow("密钥算法", value: SSLKeyType(rawValue: d.keyType)?.displayName ?? d.keyType)
        } header: {
            Text("机构详情")
        }
    }

    private func pemSection(title: String, content: String?) -> some View {
        Section {
            if let content, !content.isEmpty {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                HStack {
                    ProgressView()
                    Text("加载中…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(title)
        }
    }

    private func loadDetail() async {
        if let d = await vm.loadCADetail(id: ca.id) {
            detail = d
        }
    }

    private func doDelete() async {
        if await vm.deleteCA(id: ca.id) {
            onDeleted?()
            dismiss()
        }
    }
}

// MARK: - 创建 CA

struct CreateCAView: View {
    @ObservedObject var vm: CertificatesViewModel
    @Environment(\.dismiss) private var dismiss
    var onComplete: (() -> Void)? = nil

    @State private var name = ""
    @State private var commonName = ""
    @State private var organization = ""
    @State private var organizationUint = ""
    @State private var country = "CN"
    @State private var province = ""
    @State private var city = ""
    @State private var keyType: SSLKeyType = .EC256

    @State private var isSubmitting = false
    @State private var showValidationAlert = false
    @State private var validationMessage = ""

    var body: some View {
        Form {
            Section {
                TextField("机构名称", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("基本信息")
            }

            Section {
                TextField("证书主体名称(CN)", text: $commonName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("公司/组织", text: $organization)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("部门（可选）", text: $organizationUint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("组织信息")
            }

            Section {
                TextField("国家代号", text: $country)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("省份（可选）", text: $province)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("城市（可选）", text: $city)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("地区信息")
            }

            Section {
                Picker("密钥算法", selection: $keyType) {
                    ForEach(SSLKeyType.allCases) { k in
                        Text(k.displayName).tag(k)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("密钥")
            }
        }
        .navigationTitle("创建机构")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text("创建").bold()
                    }
                }
                .disabled(isSubmitting)
            }
        }
        .alert(validationMessage, isPresented: $showValidationAlert) {
            Button("好", role: .cancel) {}
        }
    }

    private func submit() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "请填写机构名称"
            showValidationAlert = true
            return
        }
        let trimmedCN = commonName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCN.isEmpty else {
            validationMessage = "请填写证书主体名称(CN)"
            showValidationAlert = true
            return
        }
        let trimmedOrg = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOrg.isEmpty else {
            validationMessage = "请填写公司/组织"
            showValidationAlert = true
            return
        }

        let req = CACreateRequest(
            name: trimmedName,
            keyType: keyType.rawValue,
            commonName: trimmedCN,
            country: country.trimmingCharacters(in: .whitespacesAndNewlines),
            organization: trimmedOrg,
            organizationUint: organizationUint.trimmingCharacters(in: .whitespacesAndNewlines),
            province: province.trimmingCharacters(in: .whitespacesAndNewlines),
            city: city.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        isSubmitting = true; defer { isSubmitting = false }
        if await vm.createCA(req: req) {
            onComplete?()
            dismiss()
        }
    }
}

// MARK: - 签发证书

struct IssueCertificateView: View {
    let ca: CertificateAuthority
    @ObservedObject var vm: CertificatesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var domains = ""
    @State private var description_ = ""
    @State private var keyType: SSLKeyType = .EC256
    @State private var time: Int = 10
    @State private var unit: ExpireUnit = .year
    @State private var autoRenew = true
    @State private var pushDir = false
    @State private var dir = ""
    @State private var execShell = false
    @State private var shell = ""

    @State private var isSubmitting = false
    @State private var showValidationAlert = false
    @State private var validationMessage = ""

    enum ExpireUnit: String, CaseIterable, Identifiable {
        case year = "year"
        case day = "day"
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .year: return "年"
            case .day:  return "天"
            }
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("域名（一行一个）", text: $domains, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("备注（可选）", text: $description_)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("基本信息")
            } footer: {
                Text("一行一个域名，支持 * 和 IP 地址")
            }

            Section {
                Picker("密钥算法", selection: $keyType) {
                    ForEach(SSLKeyType.allCases) { k in
                        Text(k.displayName).tag(k)
                    }
                }
                .pickerStyle(.menu)

                Stepper("有效期：\(time) \(unit.displayName)", value: $time, in: 1...9999)
                Picker("单位", selection: $unit) {
                    ForEach(ExpireUnit.allCases) { u in
                        Text(u.displayName).tag(u)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("自动续签", isOn: $autoRenew)
            } header: {
                Text("证书配置")
            }

            Section {
                Toggle("推送证书到本地目录", isOn: $pushDir.animation())
                if pushDir {
                    TextField("目录路径", text: $dir)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            Section {
                Toggle("申请证书之后执行脚本", isOn: $execShell.animation())
                if execShell {
                    TextField("脚本内容", text: $shell, axis: .vertical)
                        .lineLimit(5, reservesSpace: true)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
        }
        .navigationTitle("签发证书")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text("签发").bold()
                    }
                }
                .disabled(isSubmitting)
            }
        }
        .alert(validationMessage, isPresented: $showValidationAlert) {
            Button("好", role: .cancel) {}
        }
    }

    private func submit() async {
        let trimmedDomains = domains.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDomains.isEmpty else {
            validationMessage = "请填写域名"
            showValidationAlert = true
            return
        }
        if pushDir {
            let trimmedDir = dir.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDir.isEmpty else {
                validationMessage = "请填写推送目录路径"
                showValidationAlert = true
                return
            }
        }

        let req = CAObtainRequest(
            keyType: keyType.rawValue,
            domains: trimmedDomains,
            id: ca.id,
            time: time,
            unit: unit.rawValue,
            pushDir: pushDir,
            dir: pushDir ? dir.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            autoRenew: autoRenew,
            description: description_.trimmingCharacters(in: .whitespacesAndNewlines),
            execShell: execShell,
            shell: execShell ? shell : ""
        )

        isSubmitting = true; defer { isSubmitting = false }
        if await vm.obtainCA(req: req) {
            dismiss()
        }
    }
}
