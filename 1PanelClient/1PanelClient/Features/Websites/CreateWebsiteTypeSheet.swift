//
//  CreateWebsiteTypeSheet.swift
//  1PanelClient
//
//  创建网站的 + 号入口：半屏弹窗选择网站类型（一键部署 / 反向代理 / 静态网站），
//  选定后进入对应类型的创建向导（向导内不再切换类型）。
//

import SwiftUI

struct CreateWebsiteTypeSheet: View {
    /// 选定类型回调（弹窗自行关闭，push 由父页在关闭转场后发起）
    let onSelect: (WebsiteType) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(WebsiteType.allCases) { type in
                    Button {
                        onSelect(type)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            IconBadge(systemName: type.icon, color: .accentColor)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(type.displayName)
                                    .font(.body.bold())
                                    .foregroundStyle(.primary)
                                Text(type.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle(L10n.t("创建网站"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
            }
        }
    }
}
