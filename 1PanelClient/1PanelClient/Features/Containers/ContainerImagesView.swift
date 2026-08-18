//
//  ContainerImagesView.swift
//  1PanelClient
//

import SwiftUI

// MARK: - 镜像列表页

struct ContainerImageView: View {
    @ObservedObject var vm: ContainersViewModel
    @State private var showPull = false
    @State private var showRepos = false
    @State private var showPruneSelect = false
    @State private var showMenu = false
    /// 左滑删除的待确认镜像
    @State private var pendingDeleteImage: ContainerImage?

    var body: some View {
        Group {
            if vm.isLoadingImages && vm.images.isEmpty {
                ProgressView("加载镜像…")
            } else if vm.images.isEmpty {
                ContentUnavailableView(
                    "暂无镜像",
                    systemImage: "square.stack.3d.up",
                    description: Text(vm.errorMessage ?? "这台服务器上没有镜像")
                )
            } else {
                List {
                    ForEach(vm.images) { img in
                        ImageRow(image: img)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDeleteImage = img
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                .disabled(img.isUsed == true || (img.tags?.first ?? "").isEmpty)
                            }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await vm.loadImages() }
            }
        }
        .navigationTitle("镜像")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EllipsisMenuButton {
                    withAnimation(.easeOut(duration: 0.18)) { showMenu.toggle() }
                }
                .disabled(vm.imageOperating)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showMenu {
                EllipsisMenuPopup(entries: [
                    .action(title: "拉取镜像") { showPull = true },
                    .action(title: "仓库") { showRepos = true },
                    .divider,
                    .action(title: "清理镜像") { showPruneSelect = true },
                ]) {
                    withAnimation(.easeIn(duration: 0.12)) { showMenu = false }
                }
            }
        }
        .navigationDestination(isPresented: $showPull) {
            PullImageView(vm: vm)
        }
        .navigationDestination(isPresented: $showRepos) {
            RepoListView(vm: vm)
        }
        .navigationDestination(isPresented: $showPruneSelect) {
            ImagePruneSelectView(vm: vm)
        }
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .alert("删除镜像", isPresented: Binding(
            get: { pendingDeleteImage != nil },
            set: { if !$0 { pendingDeleteImage = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDeleteImage = nil }
            Button("删除", role: .destructive) {
                if let img = pendingDeleteImage, let name = img.tags?.first, !name.isEmpty {
                    Task { _ = await vm.deleteImages(names: [name]) }
                }
            }
        } message: {
            Text("确定删除镜像「\(pendingDeleteImage?.displayName ?? "")」吗？删除后不可恢复。")
        }
        .task {
            if vm.images.isEmpty { await vm.loadImages() }
        }
    }
}

struct ImageRow: View {
    let image: ContainerImage

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "square.stack.3d.up.fill", color: .teal, size: 34, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(image.displayName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(image.sizeDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if image.isUsed == true {
                        StatusBadge(text: "使用中", color: .green)
                    } else {
                        StatusBadge(text: "未使用", color: .gray)
                    }
                    if image.isPinned == true {
                        StatusBadge(text: "已固定", color: .orange)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 拉取镜像

struct PullImageView: View {
    @ObservedObject var vm: ContainersViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var fromRepo = true
    @State private var repos: [ContainerRepo] = []
    @State private var selectedRepoID: Int = 0
    @State private var imageNameInput = ""
    @State private var imageNames: [String] = []
    @State private var isPulling = false
    @State private var pullTaskID: String?
    @State private var showTaskProgress = false

    private var canPull: Bool {
        !imageNames.isEmpty && (!fromRepo || selectedRepoID > 0)
    }

    var body: some View {
        Form {
            Section {
                Toggle("镜像仓库", isOn: $fromRepo)

                if fromRepo {
                    if repos.isEmpty {
                        Text("暂无已配置的仓库")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("仓库名", selection: $selectedRepoID) {
                            ForEach(repos) { repo in
                                Text(repo.name ?? "未知").tag(repo.id)
                            }
                        }
                    }
                }
            }

            Section {
                ForEach(imageNames.indices, id: \.self) { idx in
                    HStack {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(.teal)
                        Text(imageNames[idx])
                            .font(.system(.subheadline, design: .monospaced))
                        Spacer()
                        Button {
                            imageNames.remove(at: idx)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red.opacity(0.7))
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                    TextField("镜像名（回车添加）", text: $imageNameInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit {
                            addImage()
                        }
                    if !imageNameInput.isEmpty {
                        Button("添加") {
                            addImage()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("镜像名")
            } footer: {
                Text("输入镜像名后回车继续添加，支持同时拉取多个镜像。")
            }

            Section {
                Button {
                    Task { await startPull() }
                } label: {
                    HStack {
                        if isPulling { ProgressView().scaleEffect(0.8) }
                        Text(isPulling ? "拉取中…" : "确认拉取")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!canPull || isPulling)
            }
        }
        .navigationTitle("拉取镜像")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            repos = await vm.loadRepos()
            if let first = repos.first { selectedRepoID = first.id }
        }
        .navigationDestination(isPresented: $showTaskProgress) {
            if let taskID = pullTaskID {
                TaskProgressView(taskID: taskID, title: "拉取镜像") { _ in
                    Task { await vm.loadImages() }
                    return false
                }
            }
        }
    }

    private func addImage() {
        let trimmed = imageNameInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        imageNames.append(trimmed)
        imageNameInput = ""
    }

    private func startPull() async {
        isPulling = true
        let taskID = await vm.pullImage(
            fromRepo: fromRepo,
            repoID: fromRepo ? selectedRepoID : 0,
            imageNames: imageNames
        )
        isPulling = false
        if let taskID {
            pullTaskID = taskID
            showTaskProgress = true
        }
    }
}


// MARK: - 镜像清理选择

struct ImagePruneSelectView: View {
    @ObservedObject var vm: ContainersViewModel
    /// false=清理未使用镜像，true=清理未标签镜像（页顶分段切换）
    @State private var isUntaggedMode = false

    @State private var selectedIDs: Set<String> = []
    @State private var isDeleting = false

    private var filteredImages: [ContainerImage] {
        if isUntaggedMode {
            return vm.images.filter { ($0.tags ?? []).isEmpty }
        } else {
            return vm.images.filter { $0.isUsed != true }
        }
    }

    private var selectedImageNames: [String] {
        filteredImages
            .filter { selectedIDs.contains($0.id) }
            .compactMap { img -> String? in
                if let tag = img.tags?.first, !tag.isEmpty { return tag }
                return nil
            }
    }

    private var allSelected: Bool {
        !filteredImages.isEmpty && filteredImages.allSatisfy { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("清理模式", selection: $isUntaggedMode) {
                Text("清理未使用镜像").tag(false)
                Text("清理未标签镜像").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Group {
                if filteredImages.isEmpty {
                    ContentUnavailableView(
                        isUntaggedMode ? "暂无未标签镜像" : "暂无未使用镜像",
                        systemImage: "checkmark.seal",
                        description: Text("没有可清理的镜像")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    List(selection: $selectedIDs) {
                        Section {
                            ForEach(filteredImages) { img in
                                HStack {
                                    if let tag = img.tags?.first, !tag.isEmpty {
                                        Text(tag)
                                            .font(.system(.subheadline, design: .monospaced))
                                    } else {
                                        Text("<none>")
                                            .font(.system(.subheadline, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(img.sizeDisplay)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(img.id)
                            }
                        } header: {
                            HStack {
                                Text(isUntaggedMode ? "未标签镜像（\(filteredImages.count)）" : "未使用镜像（\(filteredImages.count)）")
                                Spacer()
                                Button {
                                    if allSelected {
                                        selectedIDs.removeAll()
                                    } else {
                                        selectedIDs = Set(filteredImages.map(\.id))
                                    }
                                } label: {
                                    Text(allSelected ? "取消全选" : "全选")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                    .listStyle(.insetGrouped)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .navigationTitle("清理镜像")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: isUntaggedMode) { _, _ in
            // 两种模式的候选集不同，切换后清空已选
            selectedIDs.removeAll()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await deleteSelected() }
                } label: {
                    if isDeleting {
                        ProgressView()
                    } else {
                        Text("删除（\(selectedIDs.count)）")
                            .fontWeight(.medium)
                    }
                }
                .disabled(selectedIDs.isEmpty || isDeleting)
            }
        }
        .task {
            if vm.images.isEmpty { await vm.loadImages() }
        }
    }

    private func deleteSelected() async {
        let names = selectedImageNames
        guard !names.isEmpty else { return }
        isDeleting = true
        let ok = await vm.deleteImages(names: names)
        isDeleting = false
        if ok {
            selectedIDs.removeAll()
        }
    }
}

