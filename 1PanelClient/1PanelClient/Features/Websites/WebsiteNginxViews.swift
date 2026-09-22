//
//  WebsiteNginxViews.swift
//  1PanelClient
//

import SwiftUI

// MARK: - Nginx 配置编辑

struct WebsiteNginxView: View {
    let websiteId: Int
    @ObservedObject var vm: WebsitesViewModel

    @State private var config: WebsiteNginxConfig?
    @State private var content: String = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var isEditing = false

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else {
                configEditor
            }
        }
        .navigationTitle(L10n.t("配置文件"))
        .navigationBarTitleDisplayMode(.inline)
        .contentWidthLimit(860)
        .toastOverlay(message: $vm.toastMessage)
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() } else { Text(L10n.t("保存")).bold() }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .task {
            await load()
        }
    }

    @ViewBuilder
    private var configEditor: some View {
        // 按模式选择页面结构（全 App 标准模式，避免「VStack 包自滚动编辑器」
        // 的嵌套滚动/手势冲突）：
        // - 只读：页面级 ScrollView + 内嵌行号列表（CodeEditorArea 只读态无内部滚动）
        // - 编辑：TextEditor 自滚动独占剩余空间，页面不再另加滚动容器
        if isEditing {
            VStack(spacing: 12) {
                fileHeader
                CodeEditorArea(text: $content)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                editToggleButton
            }
            .padding(.vertical)
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    fileHeader
                    CodeEditorArea(text: $content, readOnly: true)
                    editToggleButton
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground))
        }
    }

    private var fileHeader: some View {
        Group {
            if let cfg = config {
                HStack {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(cfg.name ?? "nginx.conf")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
            }
        }
    }

    private var editToggleButton: some View {
        Button {
            isEditing.toggle()
            if !isEditing {
                // 取消编辑时还原
                content = config?.content ?? content
            }
        } label: {
            Label(isEditing ? L10n.t("取消编辑") : L10n.t("编辑配置"), systemImage: isEditing ? "xmark" : "pencil")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        config = await vm.loadNginxConfig(id: websiteId)
        content = config?.content ?? ""
    }

    private func save() async {
        isSaving = true
        let ok = await vm.updateNginxConfig(id: websiteId, content: content)
        isSaving = false
        if ok {
            isEditing = false
        }
    }
}


// MARK: - OpenResty 全局配置编辑

struct OpenRestyConfigView: View {
    @ObservedObject var vm: WebsitesViewModel

    @State private var configText = ""
    @State private var originalText = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var showResetConfirm = false
    @State private var showMenu = false

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else {
                CodeEditorArea(text: $configText)
            }
        }
        .navigationTitle("nginx.conf")
        .navigationBarTitleDisplayMode(.inline)
        .toastOverlay(message: $vm.toastMessage)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EllipsisMenuButton {
                    withAnimation(Motion.fast) { showMenu.toggle() }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showMenu {
                EllipsisMenuPopup(entries: [
                    .action(title: L10n.t("保存"), isDisabled: isSaving || isLoading || configText == originalText) {
                        Task { await save() }
                    },
                    .action(title: L10n.t("还原默认"), role: .destructive, isDisabled: isSaving || isLoading) {
                        showResetConfirm = true
                    },
                ]) {
                    withAnimation(Motion.fast) { showMenu = false }
                }
            }
        }
        .task { await loadConfig() }
        .alert(L10n.t("还原默认配置"), isPresented: $showResetConfirm) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("确认还原"), role: .destructive) {
                Haptic.warning()
                Task { await resetConfig() }
            }
        } message: {
            Text(L10n.t("将用默认配置覆盖当前内容，是否继续？"))
        }
    }

    private func loadConfig() async {
        isLoading = true
        defer { isLoading = false }
        if let content = await vm.loadOpenRestyConfig() {
            configText = content
            originalText = content
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await vm.saveOpenRestyConfig(content: configText, backup: false)
        if ok {
            originalText = configText
        }
    }

    private func resetConfig() async {
        isLoading = true
        defer { isLoading = false }
        if let content = await vm.resetOpenRestyConfig() {
            configText = content
            originalText = content
        }
    }
}
