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
    /// 长按菜单目标（更新/标签/删除）
    @State private var actionImage: ContainerImage?
    /// 删除待确认镜像（单 tag：直接确认弹窗）
    @State private var pendingDeleteImage: ContainerImage?
    /// 删除待选标签镜像（多 tag：「所有/单个标签」选择弹窗）
    @State private var deleteSelectImage: ContainerImage?
    /// 更新待确认镜像（单 tag：确认后走 pull 任务）
    @State private var pendingUpdateImage: ContainerImage?
    /// 更新待选标签镜像（多 tag：「所有/单个标签」选择弹窗）
    @State private var updateSelectImage: ContainerImage?
    /// 标签表单推入目标
    @State private var taggingImage: ContainerImage?
    /// 删除任务进度（taskID 非空时 push TaskProgressView）
    @State private var deleteTaskID: String?
    /// 更新任务进度（taskID 非空时 push TaskProgressView）
    @State private var updateTaskID: String?
    /// 搜索框状态（服务端分页过滤，输入防抖后重查第一页）
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var searchDebounce: Task<Void, Never>?

    /// 镜像是否可删除（原左划删除按钮的禁用条件：使用中 / 无 tag）
    private func canDelete(_ img: ContainerImage) -> Bool {
        img.isUsed != true && !(img.tags?.first ?? "").isEmpty
    }

    var body: some View {
        Group {
            if vm.isLoadingImages && vm.images.isEmpty {
                LoadingStateView()
            } else if let err = vm.imagesLoadError, vm.images.isEmpty {
                LoadErrorStateView(message: err) {
                    Task { await vm.loadImages() }
                }
            } else if vm.images.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView(
                        L10n.t("暂无镜像"),
                        systemImage: "square.stack.3d.up",
                        description: Text(L10n.t("这台服务器上没有镜像"))
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            } else {
                List {
                    ForEach(vm.images) { img in
                        ImageRow(image: img)
                            // 无点击动作：长按弹操作菜单（原左划删除收编为 更新/标签/删除）
                            .contentShape(Rectangle())
                            .onLongPressGesture(minimumDuration: 0.5) {
                                Haptic.selection()
                                actionImage = img
                            }
                            // VoiceOver 无长按手势：以自定义操作暴露同一菜单
                            .accessibilityAction(named: L10n.t("更多操作")) { actionImage = img }
                            .onAppear {
                                // 滚动到底自动追加下一页
                                if img.id == vm.images.last?.id {
                                    Task { await vm.loadMoreImages() }
                                }
                            }
                    }
                    if vm.images.count < vm.imageTotal || vm.isLoadingMoreImages {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .onAppear { Task { await vm.loadMoreImages() } }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await vm.loadImages() }
            }
        }
        .navigationTitle(L10n.t("镜像"))
        .searchIconMode(
            text: $searchText,
            isSearching: $isSearching,
            title: L10n.t("镜像"),
            prompt: L10n.t("搜索镜像名"))
        .onChange(of: searchText) { _, text in
            // 防抖 400ms 后按新过滤词重查第一页
            searchDebounce?.cancel()
            searchDebounce = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                guard vm.imageKeyword != text else { return }
                vm.imageKeyword = text
                await vm.loadImages()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EllipsisMenuButton {
                    withAnimation(Motion.fast) { showMenu.toggle() }
                }
                .disabled(vm.imageOperating)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showMenu {
                EllipsisMenuPopup(entries: [
                    .action(title: L10n.t("拉取镜像"), icon: "square.and.arrow.down") { showPull = true },
                    .action(title: L10n.t("仓库"), icon: "house.circle.fill") { showRepos = true },
                    .divider,
                    .action(title: L10n.t("清理镜像"), icon: "document.on.trash") { showPruneSelect = true },
                ]) {
                    withAnimation(Motion.fast) { showMenu = false }
                }
            }
        }
        // 长按操作弹窗（呈现时捕获目标，动作在 onDismiss 后执行，闭包晚读恒为 nil）。
        // 更新需镜像带 tag（按 名:tag 拉取）；多 tag 镜像更新/删除先弹
        // 「所有/单个标签」选择（全选删除按完整 ID、部分按标签名，均带 force）
        .sheet(isPresented: Binding(
            get: { actionImage != nil },
            set: { if !$0 { actionImage = nil } }
        )) {
            let target = actionImage
            let tagList = (target?.tags ?? []).filter { !$0.isEmpty }
            let hasTag = !tagList.isEmpty
            let isMultiTag = tagList.count > 1
            var items: [ActionMenuItem] = []
            if hasTag {
                items.append(ActionMenuItem(title: L10n.t("更新"), icon: "arrow.clockwise", color: .blue) {
                    if isMultiTag {
                        updateSelectImage = target
                    } else {
                        pendingUpdateImage = target
                    }
                })
            }
            items.append(ActionMenuItem(title: L10n.t("标签"), icon: "tag", color: .teal) {
                taggingImage = target
            })
            if let img = target, canDelete(img) {
                items.append(ActionMenuItem(title: L10n.t("删除"), icon: "trash",
                                            color: .red, role: .destructive) {
                    if isMultiTag {
                        deleteSelectImage = target
                    } else {
                        pendingDeleteImage = target
                    }
                })
            }
            return ActionBottomSheet(
                title: target?.displayName ?? L10n.t("镜像"),
                items: items,
                onDismiss: { actionImage = nil }
            )
            .bottomSheetDetents([.height(ActionBottomSheet.height(for: items.count))])
            .presentationDragIndicator(.visible)
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
        .navigationDestination(item: $taggingImage) { img in
            ImageTagView(vm: vm, image: img) {
                Task { await vm.loadImages() }
            }
        }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .toastOverlay(message: $vm.toastMessage)
        // 更新确认（对齐网页端文案）：确认后按 名:tag 走 pull 任务
        .alert(L10n.t("更新"), isPresented: Binding(
            get: { pendingUpdateImage != nil },
            set: { if !$0 { pendingUpdateImage = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingUpdateImage = nil }
            Button(L10n.t("确认"), role: .destructive) {
                Haptic.warning()
                if let img = pendingUpdateImage, let tag = img.tags?.first {
                    Task {
                        updateTaskID = await vm.pullImage(
                            fromRepo: false, repoID: 0, imageNames: [tag])
                    }
                }
                pendingUpdateImage = nil
            }
        } message: {
            Text(L10n.t("将检查镜像仓库中的同名标签，若有更新则拉取并更新本地镜像。"))
        }
        .alert(L10n.t("删除镜像"), isPresented: Binding(
            get: { pendingDeleteImage != nil },
            set: { if !$0 { pendingDeleteImage = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDeleteImage = nil }
            Button(L10n.t("删除"), role: .destructive) {
                // 单 tag：按完整镜像 ID 连标签一并删除（force）
                Haptic.warning()
                if let img = pendingDeleteImage {
                    Task { deleteTaskID = await vm.deleteImages(names: [img.id]) }
                }
            }
        } message: {
            Text(L10n.f("确定删除镜像「%@」吗？删除后不可恢复。", pendingDeleteImage?.displayName ?? ""))
        }
        // 多 tag 镜像删除：先选「所有/单个标签」——全选按完整 ID 提交
        // （连同全部标签一次移除），部分选按标签名提交（抓包 2026-10-02）
        .sheet(item: $deleteSelectImage) { img in
            ImageTagPickerSheet(
                mode: .delete,
                tags: (img.tags ?? []).filter { !$0.isEmpty }
            ) { all, selected in
                deleteSelectImage = nil
                Haptic.warning()
                Task {
                    deleteTaskID = await vm.deleteImages(names: all ? [img.id] : selected)
                }
            } onCancel: {
                deleteSelectImage = nil
            }
        }
        // 多 tag 镜像更新：先选「所有/单个标签」——全选提交全部标签，
        // 部分选提交所选标签（pull 按标签逐一检查更新，抓包 2026-10-02）
        .sheet(item: $updateSelectImage) { img in
            ImageTagPickerSheet(
                mode: .update,
                tags: (img.tags ?? []).filter { !$0.isEmpty }
            ) { all, selected in
                updateSelectImage = nil
                Task {
                    updateTaskID = await vm.pullImage(
                        fromRepo: false,
                        repoID: 0,
                        imageNames: all ? (img.tags ?? []).filter { !$0.isEmpty } : selected)
                }
            } onCancel: {
                updateSelectImage = nil
            }
        }
        // 删除任务进度页；完成或转后台后刷新列表并返回
        .navigationDestination(isPresented: Binding(
            get: { deleteTaskID != nil },
            set: { if !$0 { deleteTaskID = nil } }
        )) {
            if let taskID = deleteTaskID {
                TaskProgressView(taskID: taskID, title: L10n.t("删除镜像")) { _ in
                    Task { await vm.loadImages() }
                    deleteTaskID = nil
                    return true
                }
            }
        }
        // 更新任务进度页；完成或转后台后刷新列表并返回
        .navigationDestination(isPresented: Binding(
            get: { updateTaskID != nil },
            set: { if !$0 { updateTaskID = nil } }
        )) {
            if let taskID = updateTaskID {
                TaskProgressView(taskID: taskID, title: L10n.t("更新镜像")) { _ in
                    Task { await vm.loadImages() }
                    updateTaskID = nil
                    return true
                }
            }
        }
        .onAppear {
            // 搜索框每次进页都是空（@State 随视图重建）：VM 残留上次关键词时
            // 先复位，避免列表仍按旧词过滤而搜索框为空（空结果还会误显「暂无镜像」）；
            // 从清理/拉取等子页返回同样生效
            if searchText.isEmpty && !vm.imageKeyword.isEmpty {
                vm.imageKeyword = ""
            }
            if vm.images.isEmpty { Task { await vm.loadImages() } }
        }
    }
}

struct ImageRow: View {
    let image: ContainerImage

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "square.stack.3d.up.fill", color: .teal, size: 34, cornerRadius: Radius.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(image.displayName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(image.sizeDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if image.isUsed == true {
                        StatusBadge(text: L10n.t("使用中"), color: .green)
                    } else {
                        StatusBadge(text: L10n.t("未使用"), color: .gray)
                    }
                    if image.isPinned == true {
                        StatusBadge(text: L10n.t("已固定"), color: .orange)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 多 tag 镜像的「所有/单个标签」选择弹窗

/// 多 tag 镜像删除/更新前的标签选择：勾选「所有」即全选标签，取消任一标签则
/// 「所有」同步取消（口径同清理镜像页的「所有」勾选）。打开即全选——默认动作
/// 与原「按整镜像操作」一致，一键可确认。
/// 提交语义由调用方实现：删除全选按完整 ID（连同全部标签移除）、部分选按标签名；
/// 更新提交所选标签列表（全选即全部标签）
struct ImageTagPickerSheet: View {
    enum Mode {
        case delete, update

        var title: String {
            self == .delete ? L10n.t("删除镜像") : L10n.t("更新镜像")
        }

        /// 确认按钮文案（跟随选择数量，与清理镜像页同款）
        func confirmTitle(selectedCount: Int, totalCount: Int) -> String {
            if selectedCount == totalCount {
                return L10n.t(self == .delete ? "删除（所有）" : "更新（所有）")
            }
            return L10n.f(self == .delete ? "删除（%ld）" : "更新（%ld）", selectedCount)
        }
    }

    let mode: Mode
    /// 镜像标签（调用方已滤空）
    let tags: [String]
    /// all=true 表示「所有」全选；selected 为按原顺序排列的所选标签
    var onConfirm: (_ all: Bool, _ selected: [String]) -> Void
    var onCancel: () -> Void

    @State private var selectedTags: Set<String>

    init(mode: Mode, tags: [String],
         onConfirm: @escaping (_ all: Bool, _ selected: [String]) -> Void,
         onCancel: @escaping () -> Void) {
        self.mode = mode
        self.tags = tags
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _selectedTags = State(initialValue: Set(tags))
    }

    private var isAllSelected: Bool {
        !tags.isEmpty && selectedTags.count == tags.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    tagRow(title: L10n.t("所有"), bold: true, selected: isAllSelected) {
                        selectedTags = isAllSelected ? [] : Set(tags)
                    }
                    ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                        tagRow(title: tag, bold: false, selected: selectedTags.contains(tag)) {
                            if selectedTags.contains(tag) {
                                selectedTags.remove(tag)
                            } else {
                                selectedTags.insert(tag)
                            }
                        }
                    }
                } footer: {
                    Text(mode == .delete
                         ? L10n.t("选择「所有」将连同全部标签一并删除；也可以只删除所选标签。")
                         : L10n.t("将检查所选标签的镜像仓库更新并拉取。"))
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("取消"), role: .cancel) { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let selected = tags.filter { selectedTags.contains($0) }
                        onConfirm(isAllSelected, selected)
                    } label: {
                        Text(mode.confirmTitle(
                            selectedCount: selectedTags.count,
                            totalCount: tags.count))
                            .fontWeight(.medium)
                    }
                    .disabled(selectedTags.isEmpty)
                }
            }
        }
        .bottomSheetDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func tagRow(
        title: String,
        bold: Bool,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            // plain 样式命中区只有文字部分，补全行矩形命中
            HStack {
                Text(title)
                    .font(bold ? .subheadline.bold() : .dataMonospaced)
                    .foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 镜像打标签

/// 镜像打标签表单（POST /containers/image/tag {sourceID, tags}，抓包 2026-10-01）。
/// 「镜像仓库」开关与仓库名下拉对齐网页端表单，但均不参与提交（实测开与关请求体相同）
struct ImageTagView: View {
    @ObservedObject var vm: ContainersViewModel
    let image: ContainerImage
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// 镜像仓库默认关（与网页端一致；开关与仓库名均不参与提交）
    @State private var fromRepo = false
    @State private var repos: [ContainerRepo] = []
    @State private var selectedRepoID = 0
    /// 现有标签回填（一行一个；提交时按行拆分）
    @State private var tagsText: String
    @State private var isSubmitting = false
    @State private var showValidationAlert = false

    init(vm: ContainersViewModel, image: ContainerImage, onDone: @escaping () -> Void) {
        self.vm = vm
        self.image = image
        self.onDone = onDone
        _tagsText = State(initialValue: (image.tags ?? []).joined(separator: "\n"))
    }

    /// 仓库名下拉 Int ↔ String（OutlinedPicker 用 String）
    private var repoIDBinding: Binding<String> {
        Binding<String>(
            get: { String(selectedRepoID) },
            set: { selectedRepoID = Int($0) ?? 0 }
        )
    }

    var body: some View {
        Form {
            Section(L10n.t("来源")) {
                Toggle(L10n.t("镜像仓库"), isOn: $fromRepo)
                if fromRepo {
                    if repos.isEmpty {
                        Text(L10n.t("暂无已配置的仓库"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        OutlinedPicker(
                            label: L10n.t("仓库名"),
                            options: repos.map { String($0.id) },
                            selection: repoIDBinding,
                            optionLabels: Dictionary(uniqueKeysWithValues:
                                repos.map { (String($0.id), $0.name ?? L10n.t("未知")) }))
                    }
                }
            }

            Section {
                OutlinedMultiLineField(label: L10n.t("镜像标签"),
                                       lines: 4, fixedLines: 4,
                                       monospaced: true, text: $tagsText)
            } footer: {
                Text(L10n.t("一行一个标签（如 nginx:alpine-old）"))
            }
        }
        .navigationTitle(L10n.t("标签"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSubmitting ? L10n.t("保存中…") : L10n.t("确认")) {
                    Task { await submit() }
                }
                .disabled(isSubmitting)
            }
        }
        .alert(L10n.t("提示"), isPresented: $showValidationAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(L10n.t("请填写镜像标签"))
        }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .task {
            // 仓库名仅表单展示（不参与提交），加载失败静默为空
            repos = (try? await vm.loadRepos()) ?? []
            if let first = repos.first { selectedRepoID = first.id }
        }
    }

    private func submit() async {
        let tags = tagsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tags.isEmpty else {
            showValidationAlert = true
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        if await vm.tagImage(sourceID: image.id, tags: tags) {
            vm.showToast(L10n.t("镜像标签已保存"))
            onDone()
            dismiss()
        }
    }
}

// MARK: - 拉取镜像

struct PullImageView: View {
    @ObservedObject var vm: ContainersViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var fromRepo = true
    @State private var repos: [ContainerRepo] = []
    @State private var selectedRepoID: Int = 0
    /// 镜像名（形态 7.1：一行一个，提交时拆分）
    @State private var namesText = ""
    @State private var isPulling = false
    @State private var pullTaskID: String?
    @State private var showTaskProgress = false

    /// 提交用镜像名列表（按行拆分、去空白行）
    private var imageNames: [String] {
        namesText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var canPull: Bool {
        !imageNames.isEmpty && (!fromRepo || selectedRepoID > 0)
    }

    var body: some View {
        Form {
            Section {
                Toggle(L10n.t("镜像仓库"), isOn: $fromRepo)

                if fromRepo {
                    if repos.isEmpty {
                        Text(L10n.t("暂无已配置的仓库"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(L10n.t("仓库名"), selection: $selectedRepoID) {
                            ForEach(repos) { repo in
                                Text(repo.name ?? L10n.t("未知")).tag(repo.id)
                            }
                        }
                    }
                }
            }

            Section {
                OutlinedMultiLineField(label: L10n.t("镜像名"),
                                       lines: 4, fixedLines: 4,
                                       monospaced: true, text: $namesText)
            } footer: {
                Text(L10n.t("一行一个镜像名，可同时拉取多个。"))
            }
        }
        .navigationTitle(L10n.t("拉取镜像"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await startPull() }
                } label: {
                    if isPulling {
                        ProgressView()
                    } else {
                        Text(L10n.t("拉取")).bold()
                    }
                }
                .disabled(!canPull || isPulling)
            }
        }
        .task {
            // 拉取表单仅需仓库名列表，加载失败静默为空（表单会提示暂无仓库）
            repos = (try? await vm.loadRepos()) ?? []
            if let first = repos.first { selectedRepoID = first.id }
        }
        .navigationDestination(isPresented: $showTaskProgress) {
            if let taskID = pullTaskID {
                TaskProgressView(taskID: taskID, title: L10n.t("拉取镜像")) { _ in
                    Task { await vm.loadImages() }
                    return false
                }
            }
        }
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

    /// 候选集自取全量列表（image/all）：列表页已改分页搜索，
    /// 未翻到的页不应从清理候选中消失
    @State private var allImages: [ContainerImage] = []
    @State private var isLoading = true
    @State private var loadError: String?
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
            return allImages.filter { ($0.tags ?? []).isEmpty }
        } else {
            return allImages.filter { $0.isUsed != true }
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
            Picker(L10n.t("清理模式"), selection: $isUntaggedMode) {
                Text(L10n.t("清理未使用镜像")).tag(false)
                Text(L10n.t("清理未标签镜像")).tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Group {
                if isLoading {
                    LoadingStateView()
                        .frame(maxHeight: .infinity)
                } else if let err = loadError {
                    // 请求失败独立错误态：静默为空会误显「暂无未使用镜像」
                    LoadErrorStateView(message: err) {
                        Task { await loadAll() }
                    }
                    .frame(maxHeight: .infinity)
                } else if filteredImages.isEmpty {
                    ContentUnavailableView(
                        isUntaggedMode ? L10n.t("暂无未标签镜像") : L10n.t("暂无未使用镜像"),
                        systemImage: "checkmark.seal.fill",
                        description: Text(L10n.t("没有可清理的镜像"))
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    List(selection: $selectedIDs) {
                        Section {
                            // 「所有」勾选项：勾选后删除走 prune 接口直接清理全部
                            HStack {
                                Text(L10n.t("所有"))
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
                                            .font(.dataMonospaced)
                                    } else {
                                        // 无 tag 镜像显示 ID 前 12 位（如 8541484afbc9）
                                        Text(img.displayName)
                                            .font(.dataMonospaced)
                                    }
                                    Spacer()
                                    Text(img.sizeDisplay)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(img.id)
                            }
                        } header: {
                            Text(isUntaggedMode ? L10n.f("未标签镜像（%ld）", filteredImages.count) : L10n.f("未使用镜像（%ld）", filteredImages.count))
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                    .listStyle(.insetGrouped)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .navigationTitle(L10n.t("清理镜像"))
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
                TaskProgressView(taskID: taskID, title: L10n.t("清理镜像")) { _ in
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
                        Text(isSelectAll ? L10n.t("删除（所有）") : L10n.f("删除（%ld）", selectedIDs.count))
                            .fontWeight(.medium)
                    }
                }
                .disabled(selectedIDs.isEmpty || isDeleting)
            }
        }
        .task {
            await loadAll()
        }
    }

    private func loadAll() async {
        isLoading = true
        defer { isLoading = false }
        do {
            allImages = try await vm.fetchAllImages()
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
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

