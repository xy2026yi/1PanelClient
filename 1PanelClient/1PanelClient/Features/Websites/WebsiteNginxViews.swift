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
        .refreshable { await load() }
    }

    private var configEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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

                if isEditing {
                    TextEditor(text: $content)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 480)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                        .padding(.horizontal)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(content)
                            .font(.system(size: 12, design: .monospaced))
                            .padding()
                            .textSelection(.enabled)
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                    .padding(.horizontal)
                }

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
            .padding(.vertical)
        }
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
                TextEditor(text: $configText)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
        .navigationTitle("nginx.conf")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EllipsisMenuButton {
                    withAnimation(.easeOut(duration: 0.18)) { showMenu.toggle() }
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
                    withAnimation(.easeIn(duration: 0.12)) { showMenu = false }
                }
            }
        }
        .task { await loadConfig() }
        .refreshable { await loadConfig() }
        .alert(L10n.t("还原默认配置"), isPresented: $showResetConfirm) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("确认还原"), role: .destructive) {
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
