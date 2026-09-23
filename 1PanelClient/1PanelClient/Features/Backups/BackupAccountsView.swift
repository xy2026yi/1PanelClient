//
//  BackupAccountsView.swift
//  1PanelClient
//
//  备份账号管理：MINIO / 阿里云OSS / WebDAV / SFTP 账号 列表 / 新增 / 编辑 / 删除。
//  新增与编辑需先「连接测试」通过才能保存（与网页端一致）；
//  accessKey / credential 以 base64 提交（后端解码），凭证仅在勾选
//  「记住认证信息」后才会回显。接口字段通过 logs/备份账号.md、logs/0818-新增备份.md 抓包验证。
//

import SwiftUI
import Combine

// MARK: - 账号列表页

struct BackupAccountsView: View {
    @StateObject private var vm: BackupAccountsViewModel
    @State private var showCreate = false
    @State private var pendingDelete: BackupAccount?

    init(server: ServerConfig) {
        _vm = StateObject(wrappedValue: PageVMStore.shared.vm(key: ManageItem.backupAccount.storeKey(server: server)) {
            BackupAccountsViewModel(server: server)
        })
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.accounts.isEmpty {
                LoadingStateView()
            } else if vm.accounts.isEmpty && vm.loadFailed {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(L10n.t("无法连接服务器，请检查网络后重试"))
                } actions: {
                    Button(L10n.t("重试")) {
                        Task { await vm.refresh() }
                    }
                }
            } else if vm.accounts.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无备份账号"),
                    systemImage: "externaldrive.badge.icloud",
                    description: Text(L10n.t("点击右上角 + 添加对象存储 / 网盘 / WebDAV / SFTP 等备份账号"))
                )
            } else {
                accountList
            }
        }
        .navigationTitle(L10n.t("备份账号"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("添加备份账号"))
            }
        }
        .navigationDestination(isPresented: $showCreate) {
            BackupAccountEditView(vm: vm, existing: nil) {
                Task { await vm.refresh() }
            }
        }
        .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.refresh() } }
        .refreshable { await vm.refresh() }
        .alert(L10n.t("删除备份账号"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDelete = nil }
            Button(L10n.t("删除"), role: .destructive) {
                Haptic.warning()
                if let account = pendingDelete {
                    Task {
                        if await vm.deleteAccount(id: account.id) {
                            await vm.refresh()
                        }
                    }
                }
                pendingDelete = nil
            }
        } message: {
            if let account = pendingDelete {
                Text(L10n.f("确定删除账号「%@」吗？使用该账号的计划任务备份将失败。", account.name ?? "—"))
            }
        }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
    }

    private var accountList: some View {
        List {
            Section {
                ForEach(vm.accounts) { account in
                    if account.isEditable {
                        NavigationLink {
                            BackupAccountEditView(vm: vm, existing: account) {
                                Task { await vm.refresh() }
                            }
                        } label: {
                            BackupAccountRow(account: account)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !account.isProtected {
                                Button(role: .destructive) {
                                    pendingDelete = account
                                } label: {
                                    Label(L10n.t("删除"), systemImage: "trash")
                                }
                            }
                        }
                    } else {
                        BackupAccountRow(account: account)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if !account.isProtected {
                                    Button(role: .destructive) {
                                        pendingDelete = account
                                    } label: {
                                        Label(L10n.t("删除"), systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
            } footer: {
                Text(L10n.t("本机账号（LOCAL）为面板内置账号，不可删除；点击账号可编辑"))
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - 账号行

struct BackupAccountRow: View {
    let account: BackupAccount

    private var typeIcon: (name: String, color: Color) {
        switch account.type {
        case "LOCAL":  return ("internaldrive", .gray)
        case "MINIO":  return ("externaldrive.badge.icloud", .orange)
        case "OSS":    return ("externaldrive.badge.icloud", .indigo)
        case "WebDAV": return ("externaldrive.connected.to.line.below", .blue)
        case "SFTP":   return ("externaldrive.badge.timemachine", .green)
        case "COS":    return ("externaldrive.badge.icloud", .teal)
        case "S3":     return ("externaldrive.badge.icloud", .yellow)
        case "KODO":   return ("externaldrive.badge.icloud", .mint)
        case "UPYUN":  return ("externaldrive.connected.to.line.below", .cyan)
        case "ALIYUN": return ("externaldrive.badge.person.cloud", .blue)
        case "OneDrive": return ("externaldrive.badge.icloud", .blue)
        case "GoogleDrive": return ("externaldrive.badge.icloud", .red)
        default:       return ("externaldrive", .purple)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: typeIcon.name, color: typeIcon.color, cornerRadius: Radius.medium)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(account.displayName)
                        .font(.body.bold())
                        .lineLimit(1)
                    if account.isProtected {
                        StatusBadge(text: L10n.t("内置"), color: .secondary)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(account.displayType)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(account.displayCreatedAt)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let bucket = account.bucket, !bucket.isEmpty {
            parts.append(L10n.f("桶: %@", bucket))
        }
        if let path = account.backupPath, !path.isEmpty {
            parts.append(path)
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

