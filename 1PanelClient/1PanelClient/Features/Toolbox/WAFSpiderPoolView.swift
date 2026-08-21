//
//  WAFSpiderPoolView.swift
//  1PanelClient
//
//  WAF 蜘蛛 IP 池：启用 / 蜘蛛放行范围 / 更新
//

import SwiftUI

// MARK: - 蜘蛛 IP 池

struct WAFSpiderPoolView: View {
    let server: ServerConfig
    let item: WAFRuleItem?

    /// 蜘蛛放行范围选项（顺序即保存提交顺序）
    private static let options: [(name: String, value: String)] = [
        ("百度", "baidu"),
        ("谷歌", "google"),
        ("GPTBot", "gptbot"),
        ("必应", "bing"),
        ("今日头条", "bytes"),
        ("搜狗", "sogou"),
        ("神马搜索", "shenma"),
        ("DuckDuckGo", "duckduckgo"),
        ("360搜索", "360"),
        ("Yandex", "yandex"),
    ]

    private static let allValues: [String] = options.map(\.value)

    @State private var selected: Set<String>
    /// item 不可变，开关需本地镜像，成功保持、失败回滚，否则弹窗触发重绘时回跳
    @State private var isEnabled: Bool
    @State private var isSaving = false
    @State private var isUpdating = false
    @State private var successMessage: String?
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, item: WAFRuleItem?) {
        self.server = server
        self.item = item
        self.client = APIClient(server: server)
        // 全局配置带 rules 则按其回显，否则默认全选
        _selected = State(initialValue: Set(item?.rules ?? Self.allValues))
        _isEnabled = State(initialValue: item?.isOn ?? false)
    }

    private var allSelected: Bool { Self.allValues.allSatisfy { selected.contains($0) } }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { isEnabled },
                    set: { newVal in
                        isEnabled = newVal
                        Task { await toggle(newVal) }
                    }
                )) {
                    Text(L10n.t("启用"))
                }
            } header: {
                Text(L10n.t("蜘蛛 IP 池"))
            }

            Section {
                Button {
                    if allSelected {
                        selected.removeAll()
                    } else {
                        selected = Set(Self.allValues)
                    }
                } label: {
                    masterRow
                }
                ForEach(Self.options, id: \.value) { opt in
                    Button {
                        if selected.contains(opt.value) {
                            selected.remove(opt.value)
                        } else {
                            selected.insert(opt.value)
                        }
                    } label: {
                        spiderRow(title: L10n.t(opt.name), value: opt.value, isSelected: selected.contains(opt.value))
                    }
                }
            } header: {
                Text(L10n.t("蜘蛛放行范围"))
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    actionLabel(icon: "square.and.arrow.down", title: L10n.t("保存"), loading: isSaving)
                }
                .disabled(isSaving || isUpdating)

                Button {
                    Task { await update() }
                } label: {
                    actionLabel(icon: "arrow.triangle.2.circlepath", title: L10n.t("更新"), loading: isUpdating)
                }
                .disabled(isSaving || isUpdating)
            }
        }
        .navigationTitle(L10n.t("蜘蛛 IP 池"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { successMessage != nil || errorMessage != nil },
            set: { _ in successMessage = nil; errorMessage = nil }
        )) {
            Button(L10n.t("好的")) { successMessage = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? successMessage ?? "")
        }
    }

    // MARK: - 行视图

    private var masterRow: some View {
        let isSelected = allSelected
        let isPartial = !isSelected && !selected.isEmpty
        return HStack {
            Text(L10n.t("所有"))
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : (isPartial ? "minus.circle.fill" : "circle"))
                .foregroundStyle(isSelected || isPartial ? Color.accentColor : .secondary)
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
    }

    private func spiderRow(title: String, value: String, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(value).font(.caption).monospaced().foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
    }

    private func actionLabel(icon: String, title: String, loading: Bool) -> some View {
        HStack {
            Image(systemName: icon)
            Text(title)
            Spacer()
            if loading { ProgressView() }
        }
    }

    // MARK: - 请求

    private func toggle(_ on: Bool) async {
        let req = WAFGlobalStateRequest(scope: "AllowSpider", state: on ? "on" : "off")
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafConfigGlobalState.path, body: req, as: EmptyResponse.self)
            successMessage = on ? L10n.t("已启用") : L10n.t("已禁用")
        } catch {
            isEnabled = !on
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let rules = Self.allValues.filter { selected.contains($0) }
        let req = WAFSpiderSaveRequest(rules: rules)
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafSpider.path, body: req, as: EmptyResponse.self)
            successMessage = L10n.t("保存成功")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func update() async {
        isUpdating = true
        defer { isUpdating = false }
        let req = WAFLocationUpdateRequest(type: "spiderIP")
        do {
            let _: EmptyResponse = try await client.send(path: APIEndpoint.wafLocationUpdate.path, body: req, as: EmptyResponse.self)
            successMessage = L10n.t("更新成功")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
