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
    /// 删除任务进度（taskID 非空时 push TaskProgressView）
    @State private var deleteTaskID: String?

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
                // 删除接口要求完整镜像 ID（sha256:...），tag 名会返回 404
                if let img = pendingDeleteImage {
                    Task { deleteTaskID = await vm.deleteImages(names: [img.id]) }
                }
            }
        } message: {
            Text("确定删除镜像「\(pendingDeleteImage?.displayName ?? "")」吗？删除后不可恢复。")
        }
        // 删除任务进度页；完成或转后台后刷新列表并返回
        .navigationDestination(isPresented: Binding(
            get: { deleteTaskID != nil },
            set: { if !$0 { deleteTaskID = nil } }
        )) {
            if let taskID = deleteTaskID {
                TaskProgressView(taskID: taskID, title: "删除镜像") { _ in
                    Task { await vm.loadImages() }
                    deleteTaskID = nil
                    return true
                }
            }
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
    /// 删除任务进度（taskID 非空时 push TaskProgressView）
    @State private var deleteTaskID: String?

    /// 「所有」勾选项的选中标识（勾选后删除走 prune 接口直接清理全部）
    private static let selectAllID = "__all__"

    private var isSelectAll: Bool {
        selectedIDs.contains(Self.selectAllID)
    }

    private var filteredImages: [ContainerImage] {
        if isUntaggedMode {
            return vm.images.filter { ($0.tags ?? []).isEmpty }
        } else {
            return vm.images.filter { $0.isUsed != true }
        }
    }

    /// 待删除镜像的完整 ID（sha256:...）；同一镜像可能同时存在带/不带 tag 两行，需去重
    private var selectedImageIDs: [String] {
        Array(Set(
            filteredImages
                .filter { selectedIDs.contains($0.id) }
                .map { $0.id }
        ))
    }

    /// 「所有」行合计体积（同一镜像的带/不带 tag 多行按 ID 去重）
    private var allSizeDisplay: String {
        var seen = Set<String>()
        var total: Int64 = 0
        for img in filteredImages where seen.insert(img.id).inserted {
            total += img.size ?? 0
        }
        return ContainerImage.formatSize(total)
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
                            // 「所有」勾选项：勾选后删除走 prune 接口直接清理全部
                            HStack {
                                Text("所有")
                                    .font(.subheadline.bold())
                                Spacer()
                                Text(allSizeDisplay)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(Self.selectAllID)

                            ForEach(filteredImages) { img in
                                HStack {
                                    if let tag = img.tags?.first, !tag.isEmpty {
                                        Text(tag)
                                            .font(.system(.subheadline, design: .monospaced))
                                    } else {
                                        // 无 tag 镜像显示 ID 前 12 位（如 8541484afbc9）
                                        Text(img.displayName)
                                            .font(.system(.subheadline, design: .monospaced))
                                    }
                                    Spacer()
                                    Text(img.sizeDisplay)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(img.id)
                            }
                        } header: {
                            Text(isUntaggedMode ? "未标签镜像（\(filteredImages.count)）" : "未使用镜像（\(filteredImages.count)）")
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
        .onChange(of: selectedIDs) { old, new in
            // 「所有」与具体镜像互斥，后勾选的生效
            if new.contains(Self.selectAllID), new.count > 1 {
                if old.contains(Self.selectAllID) {
                    selectedIDs.remove(Self.selectAllID)
                } else {
                    selectedIDs = [Self.selectAllID]
                }
            }
        }
        // 删除任务进度页；完成或转后台后刷新列表并返回
        .navigationDestination(isPresented: Binding(
            get: { deleteTaskID != nil },
            set: { if !$0 { deleteTaskID = nil } }
        )) {
            if let taskID = deleteTaskID {
                TaskProgressView(taskID: taskID, title: "清理镜像") { _ in
                    Task { await vm.loadImages() }
                    deleteTaskID = nil
                    selectedIDs.removeAll()
                    return true
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await deleteSelected() }
                } label: {
                    if isDeleting {
                        ProgressView()
                    } else {
                        Text(isSelectAll ? "删除（所有）" : "删除（\(selectedIDs.count)）")
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
        isDeleting = true
        defer { isDeleting = false }
        if isSelectAll {
            // 勾选「所有」：走 prune 接口直接清理全部（withTagAll：未使用=true / 未标签=false）
            deleteTaskID = await vm.pruneImages(withTagAll: !isUntaggedMode)
        } else {
            let ids = selectedImageIDs
            guard !ids.isEmpty else { return }
            deleteTaskID = await vm.deleteImages(names: ids)
        }
    }
}

