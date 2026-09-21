//
//  AlertWebhookViews.swift
//  1PanelClient
//
//  Webhook 发送方式子页：Body（预设/类型/模版）与 Headers（键值行编辑）
//

import SwiftUI

// MARK: - Body 编辑页

/// Body 页（从发送方式编辑页点击 Body 进入）。
/// 联动规则（对齐 Web 端）：
/// 1. Body 类型切换至 Form / Text → 预设自动切换为「自定义」；
/// 2. 当前为 Form / Text 且预设切换至非自定义 → Body 类型自动切回 JSON；
/// 3. 预设切换时自动填入对应模版（自定义预设例外，保留用户内容）。
struct AlertWebhookBodyView: View {
    @Binding var config: AlertWebhookConfig

    var body: some View {
        Form {
            Section {
                OutlinedPicker(label: L10n.t("预设"),
                               options: AlertWebhookPreset.allCases,
                               selection: presetBinding) { $0.displayName }

                OutlinedPicker(label: L10n.t("Body 类型"),
                               options: AlertWebhookBodyType.allCases,
                               selection: bodyTypeBinding) { $0.displayName }

                OutlinedMultiLineField(label: L10n.t("Body 模版"), lines: 8,
                                       text: templateBinding)
            } footer: {
                Text(L10n.t("提示：title=告警标题，message=告警内容，type=告警类型，nodeName=节点名称，timestamp=发生时间"))
            }

            if config.bodyTypeEnum == .form {
                fieldsSection
            }
        }
        .navigationTitle("Body")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: config.presetEnum) { _, newPreset in
            if newPreset != .custom, config.bodyTypeEnum != .json {
                config.bodyTypeEnum = .json
            }
            if let template = newPreset.defaultTemplate {
                config.body?.template = template
            }
        }
        .onChange(of: config.bodyTypeEnum) { _, newType in
            if newType != .json {
                config.presetEnum = .custom
            }
            if newType == .form, config.body?.fields == nil {
                config.body?.fields = []
            }
        }
    }

    /// Form 类型的键值对编辑（config.body.fields，值支持模版变量）
    private var fieldsSection: some View {
        Group {
            let fields = config.body?.fields ?? []
            if fields.isEmpty {
                Section {
                    Text(L10n.t("暂无字段"))
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(fields.indices, id: \.self) { index in
                Section {
                    OutlinedTextField(label: L10n.t("名称"), text: fieldKeyBinding(at: index))
                    OutlinedTextField(label: L10n.t("值"), text: fieldValueBinding(at: index))
                } header: {
                    HStack {
                        Text(L10n.f("字段-%ld", index + 1))
                        Spacer()
                        Button(L10n.t("删除")) {
                            config.body?.fields?.remove(at: index)
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                }
            }

            Section {
                Button {
                    if config.body?.fields == nil { config.body?.fields = [] }
                    config.body?.fields?.append(AlertWebhookKV(key: "", value: ""))
                } label: {
                    Label(L10n.t("添加"), systemImage: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                }
            } footer: {
                Text(L10n.t("以表单键值对提交，值支持模版变量"))
            }
        }
    }

    private func fieldKeyBinding(at index: Int) -> Binding<String> {
        Binding(get: {
            guard config.body?.fields?.indices.contains(index) == true else { return "" }
            return config.body?.fields?[index].key ?? ""
        }, set: { config.body?.fields?[index].key = $0 })
    }

    private func fieldValueBinding(at index: Int) -> Binding<String> {
        Binding(get: {
            guard config.body?.fields?.indices.contains(index) == true else { return "" }
            return config.body?.fields?[index].value ?? ""
        }, set: { config.body?.fields?[index].value = $0 })
    }

    private var presetBinding: Binding<AlertWebhookPreset> {
        Binding(get: { config.presetEnum },
                set: { config.presetEnum = $0 })
    }

    private var bodyTypeBinding: Binding<AlertWebhookBodyType> {
        Binding(get: { config.bodyTypeEnum },
                set: { config.bodyTypeEnum = $0 })
    }

    private var templateBinding: Binding<String> {
        Binding(get: { config.body?.template ?? "" },
                set: { config.body?.template = $0 })
    }
}

// MARK: - Headers 编辑页

/// Headers 页：每个 Header 一个 Section（名称/值/敏感值），
/// 头部「删除」可删至 0 行（空态有「暂无 Header」提示），页尾「添加」
struct AlertWebhookHeadersView: View {
    @Binding var config: AlertWebhookConfig

    private var headers: [AlertWebhookHeader] { config.headers ?? [] }

    /// headers 为可选数组，解包成非可选绑定供 ForEach 编辑
    private var headersBinding: Binding<[AlertWebhookHeader]> {
        Binding(get: { config.headers ?? [] },
                set: { config.headers = $0 })
    }

    var body: some View {
        Form {
            if headers.isEmpty {
                Section {
                    Text(L10n.t("暂无 Header"))
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(headersBinding) { $header in
                Section {
                    OutlinedTextField(label: L10n.t("名称"), text: $header.key)
                    OutlinedTextField(label: L10n.t("值"), text: $header.value)
                    Toggle(L10n.t("敏感值"), isOn: $header.secret)
                } header: {
                    HStack {
                        Text(L10n.f("Header-%ld", index(of: header) + 1))
                        Spacer()
                        Button(L10n.t("删除")) {
                            config.headers?.removeAll { $0.uid == header.uid }
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                }
            }

            Section {
                Button {
                    if config.headers == nil { config.headers = [] }
                    config.headers?.append(AlertWebhookHeader())
                } label: {
                    Label(L10n.t("添加"), systemImage: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .navigationTitle("Headers")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func index(of header: AlertWebhookHeader) -> Int {
        headers.firstIndex { $0.uid == header.uid } ?? 0
    }
}
