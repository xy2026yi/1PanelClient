//
//  SSLAccountsView.swift
//  1PanelClient
//
//  SSL 账户管理：Acme 账户列表 / DNS 账户列表 + 创建表单
//  基于 doc/网站-证书.md
//

import SwiftUI

// MARK: - Acme 账户列表

struct AcmeAccountListView: View {
    @ObservedObject var vm: CertificatesViewModel

    @State private var accounts: [AcmeAccount] = []
    @State private var isLoading = false
    @State private var showCreate = false
    @State private var pendingDelete: AcmeAccount?

    var body: some View {
        Group {
            if isLoading && accounts.isEmpty {
                ProgressView("加载中…")
            } else if accounts.isEmpty {
                ContentUnavailableView(
                    "暂无 Acme 账户",
                    systemImage: "person.badge.key",
                    description: Text("点击右下角「创建账户」添加第一个 Acme 账户")
                )
            } else {
                accountList
            }
        }
        .navigationTitle("Acme 账户")
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
            Button {
                showCreate = true
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor, in: Circle())
                    .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 4)
            }
            .padding(.trailing, 20)
            .padding(.bottom, 20)
            .accessibilityLabel("创建账户")
        }
        .navigationDestination(isPresented: $showCreate) {
            CreateAcmeAccountView(vm: vm)
        }
        .alert("删除 Acme 账户", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) {
                pendingDelete = nil
            }
            Button("确认", role: .destructive) {
                if let account = pendingDelete {
                    Task {
                        if await vm.deleteAcmeAccount(id: account.id) {
                            await load()
                        }
                    }
                }
            }
        } message: {
            if let account = pendingDelete {
                Text("确定要删除账户「\(account.email)」吗？此操作不可撤销。")
            }
        }
        .task { await load() }
    }

    private var accountList: some View {
        List {
            ForEach(accounts) { account in
                AcmeAccountRow(account: account)
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
        accounts = await vm.loadAcmeAccounts()
    }
}

struct AcmeAccountRow: View {
    let account: AcmeAccount

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(
                systemName: "person.badge.key.fill",
                color: .blue,
                cornerRadius: 12
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(account.email.isEmpty ? "（未设置邮箱）" : account.email)
                    .font(.body.bold())
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(AcmeType(rawValue: account.type)?.displayName ?? account.type)
                    Text("·")
                    Text(SSLKeyType(rawValue: account.keyType)?.displayName ?? account.keyType)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 创建 Acme 账户

struct CreateAcmeAccountView: View {
    @ObservedObject var vm: CertificatesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var type: AcmeType = .letsencrypt
    @State private var keyType: SSLKeyType = .EC256
    @State private var caDirURL = ""
    @State private var useEAB = false
    @State private var eabKid = ""
    @State private var eabHmacKey = ""
    @State private var useProxy = false
    @State private var isSubmitting = false
    @State private var showValidationAlert = false

    var body: some View {
        Form {
            Section {
                TextField("邮箱", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("邮箱")
            }

            Section {
                Picker("账户类型", selection: $type) {
                    ForEach(AcmeType.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.menu)

                Picker("密钥算法", selection: $keyType) {
                    ForEach(SSLKeyType.allCases) { k in
                        Text(k.displayName).tag(k)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("账户配置")
            }

            if type == .googlecloud {
                Section {
                    TextField("EAB kid", text: $eabKid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("EAB HmacKey", text: $eabHmacKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("EAB 凭证")
                }
            }

            if type == .custom {
                Section {
                    TextField("ACME 服务 URL", text: $caDirURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("使用 EAB 认证", isOn: $useEAB.animation())
                } header: {
                    Text("自定义服务")
                }

                if useEAB {
                    Section {
                        TextField("EAB kid", text: $eabKid)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("EAB HmacKey", text: $eabHmacKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("EAB 凭证")
                    }
                }
            }

            Section {
                Toggle("使用代理", isOn: $useProxy)
            } header: {
                Text("网络")
            }
        }
        .navigationTitle("创建 Acme 账户")
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
        .alert("请填写邮箱", isPresented: $showValidationAlert) {
            Button("好", role: .cancel) {}
        }
    }

    private func submit() async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showValidationAlert = true
            return
        }

        var req = AcmeCreateRequest(
            email: trimmed,
            type: type.rawValue,
            eabKid: eabKid,
            eabHmacKey: eabHmacKey,
            keyType: keyType.rawValue,
            useProxy: useProxy,
            caDirURL: caDirURL,
            useEAB: useEAB
        )
        if type == .googlecloud {
            req.useEAB = true
        }

        isSubmitting = true; defer { isSubmitting = false }
        if await vm.createAcmeAccount(req: req) {
            dismiss()
        }
    }
}

// MARK: - DNS 账户列表

struct DNSAccountListView: View {
    @ObservedObject var vm: CertificatesViewModel

    @State private var accounts: [DNSAccount] = []
    @State private var isLoading = false
    @State private var showCreate = false
    @State private var pendingDelete: DNSAccount?

    var body: some View {
        Group {
            if isLoading && accounts.isEmpty {
                ProgressView("加载中…")
            } else if accounts.isEmpty {
                ContentUnavailableView(
                    "暂无 DNS 账户",
                    systemImage: "globe.asia.australia",
                    description: Text("点击右下角「创建账户」添加第一个 DNS 账户")
                )
            } else {
                accountList
            }
        }
        .navigationTitle("DNS 账户")
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
            Button {
                showCreate = true
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor, in: Circle())
                    .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 4)
            }
            .padding(.trailing, 20)
            .padding(.bottom, 20)
            .accessibilityLabel("创建账户")
        }
        .navigationDestination(isPresented: $showCreate) {
            CreateDNSAccountView(vm: vm)
        }
        .alert("删除 DNS 账户", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) {
                pendingDelete = nil
            }
            Button("确认", role: .destructive) {
                if let account = pendingDelete {
                    Task {
                        if await vm.deleteDnsAccount(id: account.id) {
                            await load()
                        }
                    }
                }
            }
        } message: {
            if let account = pendingDelete {
                Text("确定要删除账户「\(account.name)」吗？此操作不可撤销。")
            }
        }
        .task { await load() }
    }

    private var accountList: some View {
        List {
            ForEach(accounts) { account in
                NavigationLink {
                    CreateDNSAccountView(vm: vm, existingAccount: account) {
                        Task { await load() }
                    }
                } label: {
                    DNSAccountRow(account: account)
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
        accounts = await vm.loadDnsAccounts()
    }
}

struct DNSAccountRow: View {
    let account: DNSAccount

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(
                systemName: "globe.asia.australia.fill",
                color: .green,
                cornerRadius: 12
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(account.name.isEmpty ? "（未命名）" : account.name)
                    .font(.body.bold())
                    .lineLimit(1)
                Text(DnsType(rawValue: account.type)?.displayName ?? account.type)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 创建 DNS 账户

struct CreateDNSAccountView: View {
    @ObservedObject var vm: CertificatesViewModel
    @Environment(\.dismiss) private var dismiss

    /// 传入则进入「编辑」模式，为 nil 则为「创建」
    var existingAccount: DNSAccount?
    /// 返回时回调（用于刷新列表）
    var onComplete: (() -> Void)? = nil

    @State private var name = ""
    @State private var type: DnsType = .AliYun

    // 各服务商凭证字段
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var secretID = ""
    @State private var apiKey = ""
    @State private var apiUser = ""
    @State private var email = ""
    @State private var region = ""
    @State private var clientID = ""
    @State private var password = ""

    @State private var isSubmitting = false
    @State private var showValidationAlert = false
    @State private var validationMessage = ""

    private var isEdit: Bool { existingAccount != nil }

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("名称")
            }

            Section {
                Picker("类型", selection: $type) {
                    ForEach(DnsType.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("类型")
            }

            dynamicFields
        }
        .navigationTitle(isEdit ? "编辑 DNS 账户" : "创建 DNS 账户")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text(isEdit ? "保存" : "创建").bold()
                    }
                }
                .disabled(isSubmitting)
            }
        }
        .alert(validationMessage, isPresented: $showValidationAlert) {
            Button("好", role: .cancel) {}
        }
        .task {
            if let account = existingAccount { prefill(from: account) }
        }
        .onDisappear { onComplete?() }
    }

    private func prefill(from account: DNSAccount) {
        name = account.name
        if let t = DnsType(rawValue: account.type) { type = t }
        let auth = account.authorization
        accessKey = auth?.accessKey ?? ""
        secretKey = auth?.secretKey ?? ""
        secretID = auth?.secretID ?? ""
        apiKey = auth?.apiKey ?? ""
        apiUser = auth?.apiUser ?? ""
        email = auth?.email ?? ""
        region = auth?.region ?? ""
        clientID = auth?.clientID ?? ""
        password = auth?.password ?? ""
    }

    @ViewBuilder
    private var dynamicFields: some View {
        switch type {
        case .AliYun:
            Section {
                TextField("Access Key", text: $accessKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Secret Key", text: $secretKey)
            } header: {
                Text("阿里云凭证")
            }

        case .CloudFlare:
            Section {
                TextField("EMAIL（可选）", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("API Token", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Cloudflare 凭证")
            }

        case .TencentCloud:
            Section {
                TextField("Secret ID", text: $secretID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Secret Key", text: $secretKey)
            } header: {
                Text("腾讯云凭证")
            }

        case .HuaweiCloud:
            Section {
                TextField("Access Key", text: $accessKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Secret Key", text: $secretKey)
                TextField("Region（可选）", text: $region)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("华为云凭证")
            }

        case .CloudDns:
            Section {
                TextField("Client ID（可选）", text: $clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Email（可选）", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
            } header: {
                Text("CloudDNS 凭证")
            }

        case .NameSilo:
            Section {
                TextField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("NameSilo 凭证")
            }

        case .NameCheap:
            Section {
                TextField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("API User", text: $apiUser)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("NameCheap 凭证")
            }
        }
    }

    private func submit() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "请填写名称"
            showValidationAlert = true
            return
        }

        let auth = buildAuth()
        guard !auth.isEmpty else {
            validationMessage = "请填写完整的凭证信息"
            showValidationAlert = true
            return
        }

        isSubmitting = true; defer { isSubmitting = false }

        if let account = existingAccount {
            var updated = account
            updated.name = trimmedName
            updated.type = type.rawValue
            updated.authorization = DNSAuth(
                accessKey: auth["accessKey"],
                secretKey: auth["secretKey"],
                apiKey: auth["apiKey"],
                apiUser: auth["apiUser"],
                secretID: auth["secretID"],
                region: auth["region"],
                email: auth["email"],
                clientID: auth["clientID"],
                password: auth["password"]
            )
            if await vm.updateDnsAccount(account: updated) {
                dismiss()
            }
        } else {
            if await vm.createDnsAccount(name: trimmedName, type: type.rawValue, auth: auth) {
                dismiss()
            }
        }
    }

    /// 根据当前类型构造授权字典（仅包含非空字段）
    private func buildAuth() -> [String: String] {
        var dict: [String: String] = [:]
        func put(_ key: String, _ value: String) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { dict[key] = v }
        }

        switch type {
        case .AliYun:
            put("accessKey", accessKey)
            put("secretKey", secretKey)
        case .CloudFlare:
            put("email", email)
            put("apiKey", apiKey)
        case .TencentCloud:
            put("secretID", secretID)
            put("secretKey", secretKey)
        case .HuaweiCloud:
            put("accessKey", accessKey)
            put("secretKey", secretKey)
            put("region", region)
        case .CloudDns:
            put("clientID", clientID)
            put("email", email)
            put("password", password)
        case .NameSilo:
            put("apiKey", apiKey)
        case .NameCheap:
            put("apiKey", apiKey)
            put("apiUser", apiUser)
        }
        return dict
    }
}
