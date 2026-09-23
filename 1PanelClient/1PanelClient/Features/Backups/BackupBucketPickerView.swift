//
//  BackupBucketPickerView.swift
//  1PanelClient
//
//  桶选择页（存储页入口行进入）（自 BackupAccountsView.swift 拆出，内容未改动）
//

import SwiftUI
import Combine

// MARK: - 桶选择页（存储页入口行进入）

/// 桶选择页：进入自动获取桶列表，选中行自动返回回填；获取失败可重试或手动输入。
/// vars 由表单按类型预构建（endpoint/domain/region/scType 等，endpointItem 已剥离）
struct BackupBucketPickerView: View {
    @ObservedObject var vm: BackupAccountsViewModel
    let type: String
    let vars: BackupVarsJSON
    let accessKeyID: String
    let secretKey: String
    @Binding var bucket: String

    @Environment(\.dismiss) private var dismiss
    @State private var buckets: [String] = []
    @State private var isLoading = false
    /// 获取失败弹窗提示（不再渲染页内错误态；可在弹窗中重试）
    @State private var showFetchFailAlert = false
    /// 失败原因（缺失凭证项给具体文案，请求失败为通用文案）
    @State private var fetchFailMessage = ""

    var body: some View {
        List {
            if isLoading && buckets.isEmpty {
                HStack { Spacer(); LoadingStateView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if buckets.isEmpty {
                Section {
                    Text(L10n.t("未获取到桶列表"))
                        .foregroundStyle(.secondary)
                } footer: {
                    Text(L10n.t("获取失败或列表中没有目标桶时可手动填写"))
                }
            } else {
                Section {
                    ForEach(buckets, id: \.self) { name in
                        Button {
                            bucket = name
                            dismiss()
                        } label: {
                            HStack {
                                Text(name).font(.dataMonospacedBody)
                                Spacer()
                                if name == bucket {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(L10n.f("共 %ld 个桶", buckets.count))
                }
            }

            // 获取失败或列表中没有目标桶时的兜底
            Section {
                OutlinedTextField(label: L10n.t("桶名"), text: $bucket)
            } header: {
                Text(L10n.t("手动输入"))
            } footer: {
                Text(L10n.t("获取失败或列表中没有目标桶时可手动填写"))
            }
        }
        .navigationTitle(L10n.t("选择桶"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await fetch() }
        .alert(L10n.t("提示"), isPresented: $showFetchFailAlert) {
            Button(L10n.t("重试")) { Task { await fetch() } }
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(fetchFailMessage.isEmpty ? L10n.t("获取桶失败") : fetchFailMessage)
        }
    }

    private func fetch() async {
        // 凭证缺失给出具体缺失项（Endpoint/地域等由表单页门控保证非空）
        if accessKeyID.isEmpty {
            fetchFailMessage = L10n.t("请填写 Access Key ID")
            showFetchFailAlert = true
            return
        }
        if secretKey.isEmpty {
            fetchFailMessage = L10n.t("请填写 Secret Key")
            showFetchFailAlert = true
            return
        }
        isLoading = true
        defer { isLoading = false }
        // 静默拉取：失败由本页弹窗提示（VM 级 alert 会在返回后才弹出）
        let list = await vm.fetchBuckets(
            type: type, vars: vars,
            accessKey: BackupAccountsViewModel.encodeBase64(accessKeyID),
            credential: BackupAccountsViewModel.encodeBase64(secretKey),
            alertOnError: false)
        // nil=请求失败（弹窗可重试）；成功但空列表走页内「未获取到桶列表」空态 + 手动输入兜底
        if let list {
            buckets = list
        } else {
            fetchFailMessage = L10n.t("获取桶失败")
            showFetchFailAlert = true
        }
    }
}
