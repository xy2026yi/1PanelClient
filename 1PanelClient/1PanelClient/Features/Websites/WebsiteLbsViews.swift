//
//  WebsiteLbsViews.swift
//  1PanelClient
//
//  网站负载均衡（依据 logs/网站修改与增加-1.md 抓包 2026-09-17）：
//  列表 + 创建/编辑（动态节点）+ 源文 + 删除。
//

import SwiftUI

// MARK: - 负载均衡列表

struct WebsiteLbsView: View {
    let websiteId: Int
    @ObservedObject var vm: WebsitesViewModel

    @State private var items: [WebsiteLbsItem] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showCreate = false
    @State private var editingItem: WebsiteLbsItem?
    @State private var sourceItem: WebsiteLbsItem?
    @State private var pendingDelete: WebsiteLbsItem?

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else if let err = loadError {
                LoadErrorStateView(message: err) { Task { await load() } }
            } else if items.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无负载均衡"),
                    systemImage: "scalemass",
                    description: Text(L10n.t("点击右上角创建第一个负载均衡"))
                )
            } else {
                list
            }
        }
        .navigationTitle(L10n.t("负载均衡"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(L10n.t("创建负载均衡"))
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .navigationDestination(isPresented: $showCreate) {
            WebsiteLbsEditView(websiteId: websiteId, editing: nil, vm: vm) {
                Task { await load() }
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { editingItem != nil },
            set: { if !$0 { editingItem = nil } }
        )) {
            if let item = editingItem {
                WebsiteLbsEditView(websiteId: websiteId, editing: item, vm: vm) {
                    Task { await load() }
                }
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { sourceItem != nil },
            set: { if !$0 { sourceItem = nil } }
        )) {
            if let item = sourceItem {
                WebsiteLbsSourceView(websiteId: websiteId, item: item, vm: vm)
            }
        }
        .alert(L10n.t("删除负载均衡"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDelete = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                if let item = pendingDelete {
                    pendingDelete = nil
                    Task {
                        if await vm.deleteLbs(websiteId: websiteId, name: item.name ?? "") {
                            await load()
                        }
                    }
                }
            }
        } message: {
            if let item = pendingDelete {
                Text(L10n.f("确定删除负载均衡「%@」吗？", item.name ?? ""))
            }
        }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: { Text(vm.alertMessage) }
    }

    private var list: some View {
        List {
            Section {
                ForEach(items) { item in
                    row(item)
                }
            } footer: {
                Text(L10n.t("创建负载均衡后，请前往「反向代理」，添加代理并将后端地址设置为：http://<负载均衡名称>"))
            }
        }
    }

    private func row(_ item: WebsiteLbsItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.name ?? "—")
                    .font(.body.bold())
                Spacer()
                Text(algorithmName(item.algorithm ?? "default"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.f("%ld 节点", item.servers?.count ?? 0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(Array((item.servers ?? []).prefix(3).enumerated()), id: \.offset) { _, s in
                    Text(s.server)
                        .font(.caption.monospaced())
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                }
                if (item.servers?.count ?? 0) > 3 {
                    Text("…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { editingItem = item }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = item
            } label: {
                Label(L10n.t("删除"), systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                sourceItem = item
            } label: {
                Label(L10n.t("源文"), systemImage: "doc.text")
            }
            .tint(.teal)
        }
    }

    private func algorithmName(_ raw: String) -> String {
        switch raw {
        case "ip_hash":    return L10n.t("IP 哈希")
        case "least_conn": return L10n.t("最小连接")
        default:           return L10n.t("默认")
        }
    }

    private func load() async {
        isLoading = items.isEmpty
        do {
            items = try await vm.loadLbs(websiteId: websiteId)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - 负载均衡创建/编辑

/// 节点编辑草稿（@State 数组内可变）
private struct LbsServerDraft: Identifiable {
    var server = ""
    var weight = 0
    var flag = ""
    var maxFails = 0
    var failTimeout = 0
    var failTimeoutUnit = "s"
    var maxConns = 0
    var id = UUID()

    init() {}

    init(from s: WebsiteLbsServer) {
        server = s.server
        weight = s.weight
        flag = s.flag
        maxFails = s.maxFails
        failTimeout = s.failTimeout
        failTimeoutUnit = s.failTimeoutUnit.isEmpty ? "s" : s.failTimeoutUnit
        maxConns = s.maxConns
    }

    var toServer: WebsiteLbsServer {
        WebsiteLbsServer(server: server, weight: weight, failTimeout: failTimeout,
                          failTimeoutUnit: failTimeoutUnit, maxFails: maxFails,
                          maxConns: maxConns, flag: flag)
    }
}

struct WebsiteLbsEditView: View {
    let websiteId: Int
    let editing: WebsiteLbsItem?
    @ObservedObject var vm: WebsitesViewModel
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var algorithm = "default"
    @State private var servers: [LbsServerDraft] = [LbsServerDraft()]
    @State private var isSaving = false

    private var isEdit: Bool { editing != nil }
    private let algorithms: [(String, String)] = [
        ("default", L10n.t("默认")), ("ip_hash", L10n.t("IP 哈希")), ("least_conn", L10n.t("最小连接"))
    ]

    var body: some View {
        Form {
            Section(L10n.t("基本信息")) {
                OutlinedTextField(label: L10n.t("名称"), text: $name, disabled: isEdit)
                OutlinedPicker(label: L10n.t("算法"),
                               options: algorithms.map(\.0),
                               selection: $algorithm,
                               optionLabels: Dictionary(uniqueKeysWithValues: algorithms))
            }

            ForEach($servers) { $s in
                nodeSection($s)
            }

            Section {
                Button {
                    servers.append(LbsServerDraft())
                } label: {
                    Label(L10n.t("添加节点"), systemImage: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .navigationTitle(isEdit ? L10n.t("编辑负载均衡") : L10n.t("创建负载均衡"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSaving ? L10n.t("保存中…") : L10n.t("保存")) {
                    Task { await save() }
                }
                .disabled(!canSubmit || isSaving)
            }
        }
        .onAppear(perform: fillIfEditing)
    }

    private func nodeSection(_ s: Binding<LbsServerDraft>) -> some View {
        Section {
            OutlinedTextField(label: L10n.t("地址"), prompt: "127.0.0.1:8080",
                              text: s.server, keyboardType: .URL)
            OutlinedUnitField(label: L10n.t("权重"), unit: "", prompt: L10n.t("可选"),
                              text: intBinding(s.weight), range: 0...256)
            OutlinedPicker(label: L10n.t("策略"), options: ["", "down", "backup"],
                           selection: s.flag,
                           optionLabels: ["": L10n.t("默认"),
                                          "down": L10n.t("停用"),
                                          "backup": L10n.t("备用")])
            OutlinedUnitField(label: L10n.t("最大失败次数"), unit: L10n.t("次"),
                              text: intBinding(s.maxFails), range: 0...9999)
            OutlinedUnitField(label: L10n.t("故障超时"), unit: L10n.t("秒"),
                              text: intBinding(s.failTimeout), range: 0...9999)
            OutlinedUnitField(label: L10n.t("最大连接数"), unit: "", prompt: L10n.t("可选"),
                              text: intBinding(s.maxConns), range: 0...99999)
        } header: {
            HStack {
                Text(L10n.f("节点-%ld", index(of: s.id) + 1))
                Spacer()
                // 删除以「整个节点」为单位，仅剩一个节点时不可删
                if servers.count > 1 {
                    Button {
                        servers.removeAll { $0.id == s.id }
                    } label: {
                        Label(L10n.t("删除节点"), systemImage: "trash")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private var canSubmit: Bool {
        !name.isEmpty && servers.allSatisfy { !$0.server.isEmpty }
    }

    private func index(of id: UUID) -> Int {
        servers.firstIndex { $0.id == id } ?? 0
    }

    private func intBinding(_ value: Binding<Int>) -> Binding<String> {
        Binding(get: { String(value.wrappedValue) },
                set: { value.wrappedValue = Int($0) ?? value.wrappedValue })
    }

    private func fillIfEditing() {
        guard let item = editing, name.isEmpty else { return }
        name = item.name ?? ""
        algorithm = item.algorithm ?? "default"
        servers = (item.servers ?? []).map(LbsServerDraft.init(from:))
        if servers.isEmpty { servers = [LbsServerDraft()] }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await vm.saveLbs(websiteId: websiteId, name: name, algorithm: algorithm,
                                  servers: servers.map(\.toServer), isEdit: isEdit)
        if ok {
            onDone()
            dismiss()
        }
    }
}

// MARK: - 负载均衡源文

struct WebsiteLbsSourceView: View {
    let websiteId: Int
    let item: WebsiteLbsItem
    @ObservedObject var vm: WebsitesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var content = ""
    @State private var originalContent = ""
    @State private var isSaving = false

    private var hasChanges: Bool { content != originalContent }

    var body: some View {
        CodeEditorArea(text: $content)
            .navigationTitle(L10n.f("源文：%@", item.name ?? ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                    }
                    .disabled(isSaving || !hasChanges)
                }
            }
            .onAppear {
                if content.isEmpty {
                    content = item.content ?? ""
                    originalContent = content
                }
            }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if await vm.saveLbsFile(websiteId: websiteId, name: item.name ?? "", content: content) {
            originalContent = content
            dismiss()
        }
    }
}
