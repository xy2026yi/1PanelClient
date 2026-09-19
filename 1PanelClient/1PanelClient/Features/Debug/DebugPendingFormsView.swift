//
//  DebugPendingFormsView.swift
//  1PanelClient
//
//  DEBUG 专用：「已确定目标形态的待改造项」效果预览页。
//  启动方式：模拟器带启动参数 -pendingFormsDemo 拉起（见 _PanelClientApp.swift），Release 排除。
//
//  预览三处（docs/outlined-form-adoption-assessment-2026-09.md 一.1 节）：
//  1. 证书-签发证书-有效期：OutlinedUnitField（天），已定组件直接复用；
//  2. 告警-全局设置-免打扰时段：时间描边框（推荐方案：点击弹轮盘，零输入错误）；
//  3. MySQL-建库-权限：菜单选择 + 条件多行 IP 框（默认 5 行、末行续输自动增高）。
//

#if DEBUG
import SwiftUI

// 组件（OutlinedMultiLineField / OutlinedTimeField）已提升至
// PanelShared/Shared/OutlinedField.swift，本页仅作三处待改造项的效果预览

// MARK: - 待改造项预览页

struct DebugPendingFormsView: View {
    // 证书有效期（天）
    @State private var expireDays = "3650"

    // 告警免打扰时段
    @State private var noticeStart = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var noticeEnd = Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: Date()) ?? Date()

    // MySQL 权限
    @State private var permission = "%"
    @State private var ipList = ""

    var body: some View {
        Form {
            Section {
                OutlinedUnitField(label: L10n.t("有效期"), unit: L10n.t("天"),
                                  text: $expireDays)
            } header: {
                SectionLabel(title: L10n.t("证书 · 签发证书"), systemImage: "checkmark.seal")
            } footer: {
                Text(L10n.t("原 Stepper + 年/天切换 → 统一为天"))
            }

            Section {
                OutlinedTimeField(label: L10n.t("开始时间"), date: $noticeStart)
                OutlinedTimeField(label: L10n.t("结束时间"), date: $noticeEnd)
            } header: {
                SectionLabel(title: L10n.t("告警 · 免打扰时段"), systemImage: "bell.badge")
            } footer: {
                Text(L10n.t("推荐方案：点击框弹出时间轮盘，选定回填（不可键入，零格式错误）"))
            }

            Section {
                OutlinedPicker(label: L10n.t("权限"),
                               options: ["%", "指定IP"],
                               selection: $permission,
                               optionLabels: ["%": L10n.t("所有人(%)"), "指定IP": L10n.t("指定IP")])
                if permission == "指定IP" {
                    OutlinedMultiLineField(label: "IP", prompt: "172.16.10.111,172.16.10.112",
                                        text: $ipList)
                }
            } header: {
                SectionLabel(title: L10n.t("MySQL · 创建数据库"), systemImage: "cylinder")
            } footer: {
                if permission == "指定IP" {
                    Text(L10n.t("多个IP以逗号分隔，例: 172.16.10.111,172.16.10.112"))
                }
            }
        }
        .navigationTitle(L10n.t("待改造项预览"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        DebugPendingFormsView()
    }
}
#endif
