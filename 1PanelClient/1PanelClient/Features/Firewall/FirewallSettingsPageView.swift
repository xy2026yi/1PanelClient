//
//  FirewallSettingsPageView.swift
//  1PanelClient
//
//  防火墙「设置」段内容（嵌入 FirewallView 第四段；原独立推页已并入，
//  Form 外壳与导航栏由外层 List 提供）
//

import SwiftUI
import Combine

// MARK: - 设置段（防火墙第四段）

/// 防火墙设置：禁 Ping / 面板端口白名单 / 三组防护后端。
/// 后端（系统防火墙 / 端口转发 / 容器端口防护）用下拉选择，切换需弹窗确认；
/// 错误提示与 toast 复用外层 FirewallView 的弹窗，不在此重复挂载
struct FirewallSettingsContent: View {
    @ObservedObject var vm: FirewallViewModel

    /// 待确认的后端切换（弹窗确认后才下发 select）
    @State private var pendingSwitch: BackendSwitch?
    /// 被拦截的切换（当前后端仍含运行时规则，仅提示不发请求）
    @State private var blockedSwitch: (current: String, target: String)?

    struct BackendSwitch: Identifiable {
        let subsystem: String
        let backend: String
        var id: String { "\(subsystem)/\(backend)" }
    }

    var body: some View {
        Section {
            Toggle(L10n.t("禁 Ping"), isOn: Binding(
                get: { vm.settings?.pingBlocked ?? vm.systemStatus?.pingBlocked ?? false },
                set: { on in
                    Task {
                        await vm.operateFirewall(on ? "disableBanPing" : "enableBanPing")
                    }
                }
            ))
            .disabled(vm.isOperating)
            NavigationLink {
                FirewallWhitelistView(vm: vm)
            } label: {
                HStack {
                    Text(L10n.t("面板端口白名单"))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(parseFirewallWhitelistEntries(vm.settings?.portWhiteList).count)")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            SectionLabel(title: L10n.t("基础设置"), systemImage: "gearshape")
        } footer: {
            Text(L10n.t("禁 Ping 后服务器不再响应 ICMP 探测；端口白名单外的高校验规则见任务日志。"))
        }

        backendPickerSection(title: L10n.t("系统防火墙"), subsystem: "system",
                             group: vm.settings?.system)
        backendPickerSection(title: L10n.t("端口转发"), subsystem: "forwarding",
                             group: vm.settings?.forwarding)
        backendPickerSection(title: L10n.t("容器端口防护"), subsystem: "docker",
                             group: vm.settings?.docker)
        // 下拉切换后端：弹窗确认（确认后 select，取消回弹为当前后端）
        .alert(L10n.t("确认"), isPresented: Binding(
            get: { pendingSwitch != nil },
            set: { if !$0 { pendingSwitch = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingSwitch = nil }
            Button(L10n.t("确认"), role: .destructive) {
                Haptic.warning()
                guard let sw = pendingSwitch else { return }
                pendingSwitch = nil
                Task {
                    await vm.operateBackend(subsystem: sw.subsystem, backend: sw.backend,
                                            operation: "select")
                }
            }
        } message: {
            Text(L10n.f("确认切换为 %@？", pendingSwitch?.backend ?? ""))
        }
        // 切换被拦：当前后端仍含 1Panel 运行时规则，须先重置（仅提示，不发请求）
        .alert(L10n.t("重置"), isPresented: Binding(
            get: { blockedSwitch != nil },
            set: { if !$0 { blockedSwitch = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { blockedSwitch = nil }
        } message: {
            Text(L10n.f("当前后端 %@ 仍存在 1Panel 运行时规则，请先重置该后端，再切换到 %@。重置仅清理运行时规则，数据库策略会保留，切换后可以重新初始化或同步。", blockedSwitch?.current ?? "", blockedSwitch?.target ?? ""))
        }
    }

    /// 单组防护后端：形态 3 描边菜单（未安装 / 不支持的选项不展示，
    /// 当前选中不在可选列表时兜底保留，避免无效 selection）
    private func backendPickerSection(title: String, subsystem: String,
                                      group: FirewallBackendGroup?) -> some View {
        Section {
            OutlinedPicker(label: title,
                           options: backendOptionKeys(group: group),
                           selection: backendBinding(subsystem: subsystem, group: group),
                           optionLabels: backendOptionLabels(group: group))
                .disabled(vm.isOperating)
        } header: {
            SectionLabel(title: title, systemImage: "server.rack")
        } footer: {
            if let reason = unusableReason(group: group) {
                Text(reason)
            } else {
                Text(L10n.t("切换防护后端将重建对应规则链，期间服务可能短暂中断"))
            }
        }
    }

    /// 可选后端键：可用选项 + 当前选中兜底（去重）
    private func backendOptionKeys(group: FirewallBackendGroup?) -> [String] {
        var keys = (group?.options ?? [])
            .filter { $0.installed == true && $0.supported != false }
            .compactMap { $0.name }
        if let selected = group?.selected, !selected.isEmpty,
           !(group?.options ?? []).contains(where: { $0.name == selected && $0.installed == true && $0.supported != false }) {
            keys.insert(selected, at: 0)
        }
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    private func backendOptionLabels(group: FirewallBackendGroup?) -> [String: String] {
        var labels: [String: String] = [:]
        for option in group?.options ?? [] {
            if let name = option.name { labels[name] = name.uppercased() }
        }
        if let selected = group?.selected { labels[selected] = selected.uppercased() }
        return labels
    }

    /// 选择值真源是服务端的 group.selected；用户改选仅触发确认弹窗，不直接落状态。
    /// 当前后端仍含运行时规则（settings options 中当前 name 的 initialized=true）
    /// 时不发请求，改弹「请先重置」提示（服务端此时返回 409 FW_BACKEND_CLEANUP_REQUIRED）
    private func backendBinding(subsystem: String, group: FirewallBackendGroup?) -> Binding<String> {
        Binding<String>(
            get: { group?.selected ?? "" },
            set: { chosen in
                guard let group, !chosen.isEmpty, chosen != group.selected else { return }
                if group.currentInitialized {
                    blockedSwitch = (current: group.current ?? group.selected ?? "", target: chosen)
                    return
                }
                pendingSwitch = BackendSwitch(subsystem: subsystem, backend: chosen)
            }
        )
    }

    /// 当前选中项不可用时给出原因（如「未安装 / 由发行版管控」）
    private func unusableReason(group: FirewallBackendGroup?) -> String? {
        guard let group, let selected = group.selected else { return nil }
        guard let option = (group.options ?? []).first(where: { $0.name == selected }) else {
            return nil
        }
        let reason = option.supportReason ?? option.message ?? ""
        return reason.isEmpty ? nil : L10n.f("%@：%@", selected.uppercased(), reason)
    }
}
