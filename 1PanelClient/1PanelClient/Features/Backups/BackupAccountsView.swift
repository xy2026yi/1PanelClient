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
    /// 点击/菜单「编辑」推入的账号（NavigationLink 会吞长按，改编程式推入）
    @State private var editingAccount: BackupAccount?
    /// 长按半屏菜单目标（编辑/删除；本机账号不提供删除）
    @State private var actionAccount: BackupAccount?

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
        .navigationDestination(item: $editingAccount) { account in
            BackupAccountEditView(vm: vm, existing: account) {
                Task { await vm.refresh() }
            }
        }
        .task { await PageVMStore.shared.autoRefresh(vm: vm) { await vm.refresh() } }
        .refreshable { await vm.refresh() }
        // 长按操作弹窗：编辑 / 删除（呈现时捕获目标，动作在 onDismiss 后执行，
        // 闭包晚读 actionAccount 恒为 nil）
        .sheet(isPresented: Binding(
            get: { actionAccount != nil },
            set: { if !$0 { actionAccount = nil } }
        )) {
            let target = actionAccount
            // 菜单按能力裁剪：可编辑才给「编辑」，非内置（LOCAL/localhost）才给「删除」
            var items: [ActionMenuItem] = []
            if target?.isEditable == true {
                items.append(ActionMenuItem(title: L10n.t("编辑"), icon: "pencil", color: .blue) {
                    editingAccount = target
                })
            }
            if target?.isProtected != true {
                items.append(ActionMenuItem(title: L10n.t("删除"), icon: "trash",
                                            color: .red, role: .destructive) {
                    pendingDelete = target
                })
            }
            return ActionBottomSheet(
                title: target?.displayName ?? L10n.t("备份账号"),
                items: items,
                onDismiss: { actionAccount = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: items.count))])
            .presentationDragIndicator(.visible)
        }
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
                        // 可编辑：单击进编辑、长按弹操作菜单（编辑/删除）
                        BackupAccountRow(account: account)
                            .rowTapAndLongPress(
                                onTap: { editingAccount = account },
                                onLongPress: { actionAccount = account })
                            // VoiceOver 无长按手势：以自定义操作暴露同一菜单
                            .accessibilityAction(named: L10n.t("更多操作")) { actionAccount = account }
                    } else {
                        // 客户端暂不支持编辑的类型：长按弹操作菜单（仅删除）
                        BackupAccountRow(account: account)
                            .contentShape(Rectangle())
                            .onLongPressGesture(minimumDuration: 0.5) {
                                Haptic.selection()
                                actionAccount = account
                            }
                            .accessibilityAction(named: L10n.t("更多操作")) { actionAccount = account }
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

