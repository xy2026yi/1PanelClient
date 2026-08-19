//
//  AppUpgradeViews.swift
//  1PanelClient
//

import SwiftUI

// MARK: - 升级版本选择 Sheet

struct UpgradeSheetView: View {
    let app: AppInstall
    @ObservedObject var vm: AppsViewModel
    @State private var showComposeEditor = false
    @State private var deleteOldImage = false

    var body: some View {
        Group {
            if vm.isLoadingVersions {
                ProgressView(L10n.t("查询可用版本…"))
            } else if vm.availableVersions.isEmpty {
                ContentUnavailableView(
                    L10n.t("无可用版本"),
                    systemImage: "arrow.up.circle.slash",
                    description: Text(L10n.t("该应用暂无更高版本可供升级"))
                )
            } else {
                versionList
            }
        }
        .navigationTitle(L10n.f("升级 %@", app.displayName))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 确保应用设置已加载，用于「升级后删除旧镜像」默认勾选
            if vm.appStoreConfig == nil {
                await vm.loadAppStoreConfig()
            }
            deleteOldImage = vm.appStoreConfig?.isUpgradeDeleteImage ?? false
        }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {
                if vm.pendingDismissUpgrade {
                    vm.pendingDismissUpgrade = false
                    vm.showUpgradeSheet = false
                }
            }
        } message: {
            Text(vm.alertMessage)
        }
        .navigationDestination(isPresented: $showComposeEditor) {
            if let version = vm.selectedVersion {
                ComposeEditorView(
                    app: app,
                    version: version,
                    vm: vm,
                    initialDeleteOldImage: deleteOldImage,
                    onBack: { showComposeEditor = false }
                )
            }
        }
        .navigationDestination(isPresented: $vm.showUpgradeProgress) {
            TaskProgressView(
                taskID: vm.upgradeTaskID,
                title: L10n.f("升级 %@", app.displayName),
                onComplete: { isDone in
                    vm.needsRefresh = true
                    // 重置进度状态，避免重新进入时残留
                    vm.showUpgradeProgress = false
                    if isDone {
                        // 升级完成：通过通知 pop 回应用列表（ManageTab 嵌入模式下一次性 pop AppDetailView）
                        NotificationCenter.default.post(name: .popAppDetail, object: nil)
                        // 同时关闭升级页，兼容独立模式（popAppDetail 无效时由 showUpgradeSheet=false 收起）
                        vm.showUpgradeSheet = false
                        return true
                    }
                    return false
                }
            )
        }
    }

    private var versionList: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L10n.t("升级将替换 docker-compose.yml，如有自定义修改请查看对比"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L10n.t("提示"))
            }

            Section {
                Toggle(L10n.t("升级后删除旧镜像"), isOn: $deleteOldImage)
                    .tint(.orange)
            } header: {
                Text(L10n.t("升级选项"))
            } footer: {
                Text(L10n.t("默认关闭。开启后升级请求会删除旧镜像以释放存储空间"))
            }

            Section(L10n.t("可升级到")) {
                ForEach(vm.availableVersions) { ver in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ver.version ?? "v\(ver.detailId)")
                                    .font(.body.bold())
                                Text("ID: \(ver.detailId)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if vm.upgradingVersionId == ver.detailId {
                                ProgressView()
                            }
                        }

                        HStack(spacing: 8) {
                            Button {
                                Task {
                                    let taskID = UUID().uuidString
                                    await vm.confirmUpgrade(
                                        app: app,
                                        to: ver,
                                        customCompose: nil,
                                        deleteOldImage: deleteOldImage,
                                        taskID: taskID
                                    )
                                }
                            } label: {
                                Label(L10n.t("直接升级"), systemImage: "arrow.up.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .disabled(vm.upgradingVersionId != nil)

                            Button {
                                Task {
                                    if await vm.prepareComposeEditor(app: app, version: ver) {
                                        showComposeEditor = true
                                    }
                                }
                            } label: {
                                if vm.loadingComposeVersionId == ver.detailId {
                                    HStack {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                        Text(L10n.t("加载配置"))
                                    }
                                    .frame(maxWidth: .infinity)
                                } else {
                                    Label(L10n.t("对比/编辑"), systemImage: "doc.text.magnifyingglass")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(vm.upgradingVersionId != nil || vm.loadingComposeVersionId != nil)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await vm.ignoreUpgrade(app: app, version: ver) }
                        } label: {
                            Label(L10n.t("忽略此版本"), systemImage: "eye.slash")
                        }
                    }
                }
            }

            // 忽略所有升级
            Section {
                Button(role: .destructive) {
                    Task { await vm.ignoreUpgrade(app: app) }
                } label: {
                    Label(L10n.t("忽略所有升级"), systemImage: "eye.slash")
                }

                if app.ignoredRecordID != nil {
                    Button {
                        Task { await vm.cancelIgnoreUpgrade(app: app) }
                    } label: {
                        Label(L10n.t("取消忽略升级"), systemImage: "eye")
                    }
                }
            }
        }
    }
}

// MARK: - 忽略升级列表

struct IgnoredAppsView: View {
    @ObservedObject var vm: AppsViewModel

    @State private var ignored: [AppIgnoreUpgrade] = []
    @State private var isLoading = false

    var body: some View {
        Group {
            if isLoading && ignored.isEmpty {
                ProgressView(L10n.t("加载中…"))
            } else if ignored.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无忽略记录"),
                    systemImage: "eye.slash",
                    description: Text(L10n.t("没有被忽略升级的应用"))
                )
            } else {
                List {
                    Section {
                        ForEach(ignored) { item in
                            HStack {
                                Image(systemName: "shippingbox")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name ?? L10n.t("未知应用"))
                                        .font(.body.bold())
                                    if item.scope == "all" {
                                        Text(L10n.t("忽略所有版本"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else if let v = item.version, !v.isEmpty {
                                        Text(L10n.f("忽略版本 %@", v))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task { await cancelIgnore(recordId: item.id) }
                                } label: {
                                    Label(L10n.t("取消忽略"), systemImage: "eye")
                                }
                            }
                        }
                    } header: {
                        Text(L10n.f("已忽略升级 (%ld)", ignored.count))
                    } footer: {
                        Text(L10n.t("左滑可取消忽略，恢复升级检查"))
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
            }
        }
        .navigationTitle(L10n.t("忽略升级"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            ignored = try await vm.client.send(
                path: APIEndpoint.appsIgnoredList.path,
                method: APIEndpoint.appsIgnoredList.method,
                as: [AppIgnoreUpgrade].self
            )
        } catch let err as APIError {
            // 无忽略记录时服务端返回 data=null，APIClient 已回退为空数组
            vm.alertMessage = L10n.f("加载失败：%@", err.errorDescription ?? L10n.t("未知错误"))
            vm.showAlert = true
        } catch {
            vm.alertMessage = L10n.f("加载失败：%@", error.localizedDescription)
            vm.showAlert = true
        }
    }

    private func cancelIgnore(recordId: Int) async {
        struct Req: Encodable { let id: Int }
        do {
            let _: EmptyResponse = try await vm.client.send(
                path: APIEndpoint.appsIgnoredCancel.path,
                body: Req(id: recordId),
                as: EmptyResponse.self
            )
            ignored.removeAll { $0.id == recordId }
            vm.needsRefresh = true
        } catch {
            vm.alertMessage = L10n.f("取消忽略失败：%@", error.localizedDescription)
            vm.showAlert = true
        }
    }
}

