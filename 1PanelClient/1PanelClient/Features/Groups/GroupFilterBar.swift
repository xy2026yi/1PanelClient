//
//  GroupFilterBar.swift
//  1PanelClient
//
//  通用横向 chips 筛选条（「全部」+ 各项），分组筛选（Int id）与
//  应用类别筛选（String key）共用；单项数据的列表由调用方隐藏筛选条。
//

import SwiftUI

// MARK: - 通用 chips 筛选条

struct ChipsFilterBar<ID: Hashable>: View {
    struct Item: Identifiable {
        let id: ID
        let title: String
    }

    /// 各筛选项（不含「全部」）
    let items: [Item]
    /// 「全部」对应的 id（分组为 0，应用类别为空串）
    let allID: ID
    @Binding var selectedID: ID
    /// 末尾「管理」入口（分组筛选条用；nil 则不显示）
    var onManage: (() -> Void)?

    init(items: [Item], allID: ID, selectedID: Binding<ID>, onManage: (() -> Void)? = nil) {
        self.items = items
        self.allID = allID
        self._selectedID = selectedID
        self.onManage = onManage
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 带管理入口且仅有单项数据时「全部」冗余可省；
                // 无管理入口时必须常驻，否则单项数据下无法切回「全部」
                if items.count > 1 || onManage == nil {
                    chip(L10n.t("全部"), id: allID)
                }
                ForEach(items) { item in
                    chip(item.title.isEmpty ? "—" : item.title, id: item.id)
                }
                if let onManage {
                    manageChip(onManage)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    /// 管理入口 chip：图标 + 文字，样式与普通 chip 一致但不可选中
    private func manageChip(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(L10n.t("管理"), systemImage: "folder.badge.gearshape")
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("分组管理"))
    }

    private func chip(_ title: String, id: ID) -> some View {
        let isSelected = selectedID == id
        return Button {
            guard !isSelected else { return }
            withAnimation(Motion.fast) { selectedID = id }
        } label: {
            Text(title)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - 分组筛选条（ChipsFilterBar 的 PanelGroup 适配）

/// 列表顶部分组筛选条：横向滚动 chips（「全部」+ 各分组名 + 可选「管理」入口）。
/// 无管理入口时仅一个分组（默认组）应由调用方隐藏；带管理入口时始终展示。
struct GroupFilterBar: View {
    let groups: [PanelGroup]
    /// 当前选中分组 ID（0 = 全部）
    @Binding var selectedID: Int
    /// 分组管理入口（网站页用：点击弹窗管理分组）；nil 则不显示
    var onManage: (() -> Void)?

    var body: some View {
        ChipsFilterBar(
            items: groups.map { .init(id: $0.id, title: $0.displayName) },
            allID: 0,
            selectedID: $selectedID,
            onManage: onManage
        )
    }
}
