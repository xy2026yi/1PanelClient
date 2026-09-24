//
//  CommonComponents.swift
//  1PanelClient
//
//  跨页面复用的轻量公共组件
//

import SwiftUI

// MARK: - 轻量提示（自动消失 Toast）

struct ToastOverlay: ViewModifier {
    @Binding var message: String?
    var systemImage: String = "checkmark.circle.fill"
    var iconColor: Color = .green
    /// 「减弱动态效果」开启时只做淡入淡出，不做顶部滑入
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let msg = message {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .foregroundStyle(iconColor)
                    Text(msg)
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .padding(.top, 8)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? Motion.fast : Motion.standard, value: message)
        // Toast 出现伴随触觉：绿色对勾=成功，其余（橙/红）=失败
        .onChange(of: message) { _, newValue in
            guard newValue != nil else { return }
            if iconColor == .green {
                Haptic.success()
            } else {
                Haptic.error()
            }
        }
        // 2 秒自动消失：组件内置，调用方只需赋值；
        // message 变化即重置计时（新提示重计 2 秒），置 nil 则无事可做
        .task(id: message) {
            guard message != nil else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            message = nil
        }
    }
}

extension View {
    /// 显示自动消失的轻量提示（2 秒后自动消失，无需用户确认）；
    /// 默认绿色对勾（成功语义），失败提示传 exclamationmark.triangle.fill + orange
    func toastOverlay(message: Binding<String?>,
                      systemImage: String = "checkmark.circle.fill",
                      iconColor: Color = .green) -> some View {
        modifier(ToastOverlay(message: message, systemImage: systemImage, iconColor: iconColor))
    }

    /// 本地 toast：显示 toastOverlay 并在 2 秒后自动清空 message。
    /// 供没有 ViewModel showToast 的页面使用（Toolbox 等本地 successMessage 场景）；
    /// 错误提示仍走 alert，不要混用本方法
    func localToast(message: Binding<String?>) -> some View {
        toastOverlay(message: message)
            .onChange(of: message.wrappedValue) { _, newValue in
                guard newValue != nil else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if message.wrappedValue != nil {
                        message.wrappedValue = nil
                    }
                }
            }
    }
}

// MARK: - 信息行（详情页 key-value 列表）

struct InfoRow: View {
    let key: String
    let value: String
    /// 数据值用等宽字体（IP、端口、ID 等机器数据）
    var monospaced: Bool = false

    init(key: String, value: String, monospaced: Bool = false) {
        self.key = key
        self.value = value
        self.monospaced = monospaced
    }

    /// 便捷初始化：`InfoRow("名称", value: x)`
    init(_ key: String, value: String, monospaced: Bool = false) {
        self.key = key
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .foregroundStyle(.secondary)
                .fixedSize()  // key 不截断，按内容自适应
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(monospaced ? .dataMonospaced : .subheadline)
    }
}

// MARK: - 可复制信息行（key-value + 一键复制）

/// 带复制按钮的信息行：与 InfoRow 同布局，右侧追加减号复制图标（连接信息等场景）。
struct CopyableInfoRow: View {
    let key: String
    let value: String
    /// 数据值用等宽字体（IP、端口、连接地址等机器数据）
    var monospaced: Bool = false

    init(key: String, value: String, monospaced: Bool = false) {
        self.key = key
        self.value = value
        self.monospaced = monospaced
    }

    /// 便捷初始化：`CopyableInfoRow("端口", value: x)`
    init(_ key: String, value: String, monospaced: Bool = false) {
        self.key = key
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .foregroundStyle(.secondary)
                .fixedSize()
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Button {
                UIPasteboard.general.string = value
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .font(monospaced ? .dataMonospaced : .subheadline)
    }
}

// MARK: - 密码展示行（••• + 显示切换 + 复制）

/// 密码信息行：默认打码，可切换明文、一键复制。
/// 与 InfoRow 同级使用（数据库/用户详情等页面）；`compact: true` 用于嵌套的小字号行。
struct PasswordRow: View {
    var key: String = L10n.t("密码")
    let password: String
    var compact: Bool = false

    @State private var showPassword = false

    var body: some View {
        HStack(spacing: compact ? 6 : nil) {
            Text(key)
                .font(compact ? .caption : nil)
                .foregroundStyle(.secondary)
            Spacer()
            Text(showPassword ? password : String(repeating: "•", count: min(password.count, 12)))
                .font(compact
                      ? .dataMonospacedCaption
                      : .dataMonospaced)
                .foregroundStyle(compact ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                showPassword.toggle()
            } label: {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                    .font(compact ? .caption : nil)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            Button {
                UIPasteboard.general.string = password
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(compact ? .caption : nil)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - 密码输入行（表单内：输入 + 显示切换 + 随机生成）

/// 表单里的密码输入行：SecureField/明文切换 + 随机密码按钮。
/// `showPassword` 以 Binding 暴露，便于外部在生成密码后自动切换为明文展示。
struct PasswordInputRow: View {
    @Binding var password: String
    @Binding var showPassword: Bool

    var body: some View {
        // 描边包裹式：眼睛 + 骰子内嵌框右侧（与全站密码框一致）。
        // borderless 必须保留：Form 行内多个默认样式 Button 会整行同触
        //（点眼睛会连带触发骰子重新生成密码）
        OutlinedShape(label: L10n.t("密码"), isFocused: false,
                      hasValue: !password.isEmpty,
                      trailing: {
            HStack(spacing: 10) {
                Button { showPassword.toggle() } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showPassword ? L10n.t("隐藏密码") : L10n.t("显示密码"))
                Button {
                    password = Self.randomPassword()
                } label: {
                    Image(systemName: "dice")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.t("生成随机密码"))
            }
        }) {
            Group {
                if showPassword {
                    TextField("", text: $password)
                } else {
                    SecureField("", text: $password)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
    }

    /// 16 位随机密码（去除易混淆字符 0/O、1/l/I）
    static func randomPassword(length: Int = 16) -> String {
        let chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}

// MARK: - 勾选行（选择列表行）

/// 选择列表行：等宽标题 + 右侧选中勾（checkmark.circle.fill，与设置页选择行一致）。
/// 点击行为由调用方通过 onTapGesture / Button 挂载。
struct CheckRow: View {
    let title: String
    var isSelected: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.dataMonospacedBody)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .accessibilityValue(isSelected ? L10n.t("已选中") : "")
    }
}

// MARK: - 状态圆点

/// 状态小圆点：与状态文字并排使用，如 `HStack(spacing: 4) { StatusDot(color:); Text(...) }`。
/// 与文字搭配时用默认 6pt；独立作为行首图标时传 `diameter: 10`。
struct StatusDot: View {
    let color: Color
    var diameter: CGFloat = 6

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
    }
}

// MARK: - 圆角图标徽章（列表行首的彩色图标块）

/// 用于列表行首统一展示一个 SF Symbols 图标 + 背景色块。
/// 与 Apps/Websites/Cronjobs/Certificates 的行首图标视觉一致。
struct IconBadge: View {
    let systemName: String
    var color: Color = .accentColor
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 12
    var backgroundOpacity: Double = 0.15

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(color.opacity(backgroundOpacity))
                .frame(width: size, height: size)
            Image(systemName: systemName)
                .font(.panelScaled(size * 0.48, weight: .semibold))
                .foregroundStyle(color)
        }
    }
}

// MARK: - 状态徽章（小胶囊标签）

/// 用于状态、类型等小标签，统一样式与色调。
struct StatusBadge: View {
    let text: String
    var color: Color = .secondary
    var icon: String? = nil
    var backgroundOpacity: Double = 0.15
    /// 等宽数字/字符（如 CPU 百分比、PID 等数据徽章）
    var monospaced: Bool = false
    /// 键值两段式胶囊的前置键名（「类型 网站」等元数据行）：键用 secondary、值用主样式。
    /// 为空即普通单段徽章，既有调用点不受影响
    var label: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2.bold())
            }
            if let label {
                Text(label)
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(monospaced ? .caption2.monospaced().bold() : .caption2.bold())
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(color.opacity(backgroundOpacity))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }
}

// MARK: - 日志跟随最新浮动按钮

/// 日志流「跟随最新」浮动胶囊：跟随中高亮；点击由调用方触发滚动到底。
/// Compose 日志 / 应用日志等流式页面共用
struct FollowLatestButton: View {
    let isFollowing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(L10n.t("跟随最新"), systemImage: "arrow.down")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isFollowing ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
                .foregroundStyle(isFollowing ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 图表空数据占位

/// 监控图表卡内的空数据占位：与图表同高，避免空白坐标轴让用户误以为图表坏了。
/// 页面/Section 级空态仍统一 ContentUnavailableView；本组件只用于图表卡内部。
struct ChartEmptyPlaceholder: View {
    var text: String = L10n.t("暂无监控数据")
    var hint: String? = nil
    var height: CGFloat = 160
    /// 矮位小卡（GPU 进程占用条等 64pt 级）：caption 字号 + 三级色
    var compact: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            Text(text)
                .font(compact ? .caption : .subheadline)
                .foregroundStyle(compact ? .tertiary : .secondary)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }
}

// MARK: - 错误重试横幅

struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 72, height: 72)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.panelScaled(30))
                    .foregroundStyle(.orange)
            }
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            Button(L10n.t("重试"), action: retry)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(.top, 48)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 全页加载失败态（错误信息 + 重试）

/// 列表页「加载失败」统一分支。错误不应折叠进空态 description（失败后无恢复路径，
/// 空态文案还会误导），统一用本视图提供重试入口
struct LoadErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button(L10n.t("重试"), action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - 区块标题（小节 header 内的图标 + 文字）

/// 给 Section header 一致的图标+文字风格
struct SectionLabel: View {
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.bold())
            }
            Text(title)
        }
    }
}

// MARK: - 搜索图标模式（右上角放大镜 → 点击展开整行搜索条）

/// 把 `.searchable` 替换为图标触发的搜索模式：
/// - 非搜索态：正常标题 + 右上角放大镜
/// - 搜索态：中=输入框 / 右=取消，占据整行
/// （使用处均为 push 进入的子页面，导航栏自带返回按钮，不再叠加自定义返回箭头）
struct SearchIconModifier: ViewModifier {
    @Binding var text: String
    @Binding var isSearching: Bool
    let title: String
    let prompt: String
    /// 键盘「搜索」提交回调（服务端搜索语义的页面用；本地实时过滤的页面不传）
    var onSubmit: (() -> Void)? = nil

    func body(content: Content) -> some View {
        content
            .navigationTitle(isSearching ? "" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isSearching {
                    ToolbarItem(placement: .principal) {
                        TextField(prompt, text: $text)
                            .textFieldStyle(.plain)
                            .submitLabel(.search)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { onSubmit?() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            endSearch()
                        } label: {
                            Text(L10n.t("取消"))
                        }
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isSearching = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                }
            }
    }

    private func endSearch() {
        text = ""
        isSearching = false
    }
}

extension View {
    /// 应用搜索图标模式
    func searchIconMode(
        text: Binding<String>,
        isSearching: Binding<Bool>,
        title: String,
        prompt: String,
        onSubmit: (() -> Void)? = nil
    ) -> some View {
        modifier(SearchIconModifier(
            text: text,
            isSearching: isSearching,
            title: title,
            prompt: prompt,
            onSubmit: onSubmit
        ))
    }
}

// MARK: - 输入确认 Sheet（高危操作：输入指定文本才能确认）

/// 高危操作确认弹窗模板：输入 expectedText 指定的文本（如名称或「立即重启」）后才能点击确认。
/// 「删除数据库/用户/任务」「面板重启确认」等弹窗的统一样式；如需附加选项（Toggle 等），
/// 通过 `options` 传入额外的 Form 内容（如 `Section("选项") { Toggle(...) }`）。
///
/// 使用方式：
/// ```
/// .sheet(isPresented: $showDelete) {
///     TextInputConfirmSheet(
///         title: "删除数据库",
///         message: "此操作不可恢复。请输入数据库名称「\(name)」以确认删除。",
///         expectedText: name,
///         fieldLabel: "确认名称",
///         fieldPlaceholder: "数据库名称"
///     ) {
///         delete()
///     }
/// }
/// ```
struct TextInputConfirmSheet<Options: View>: View {
    let title: String
    /// 顶部提示文案
    let message: String
    /// 必须完整输入的确认文本
    let expectedText: String
    /// 输入框 Section 标题
    var fieldLabel: String = L10n.t("确认输入")
    /// 输入框占位符，默认与确认文本一致
    var fieldPlaceholder: String?
    /// 确认按钮文案
    var confirmTitle: String = L10n.t("删除")

    let onConfirm: () async -> Void
    @ViewBuilder var options: () -> Options

    init(
        title: String,
        message: String,
        expectedText: String,
        fieldLabel: String = L10n.t("确认输入"),
        fieldPlaceholder: String? = nil,
        confirmTitle: String = L10n.t("删除"),
        onConfirm: @escaping () async -> Void,
        @ViewBuilder options: @escaping () -> Options = { EmptyView() }
    ) {
        self.title = title
        self.message = message
        self.expectedText = expectedText
        self.fieldLabel = fieldLabel
        self.fieldPlaceholder = fieldPlaceholder
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        self.options = options
    }

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var isSubmitting = false

    private var canConfirm: Bool {
        input.trimmingCharacters(in: .whitespaces) == expectedText
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section(fieldLabel) {
                    TextField(fieldPlaceholder ?? expectedText, text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                options()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .destructive) {
                        guard !isSubmitting else { return }
                        Haptic.warning()
                        isSubmitting = true
                        Task {
                            await onConfirm()
                            dismiss()
                        }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text(confirmTitle)
                        }
                    }
                    .disabled(!canConfirm || isSubmitting)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
        .bottomSheetDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - List 行留白（统一两套高频 listRowInsets 样板）

extension View {
    /// 监控卡内紧凑行：去掉上下默认留白（MonitorView 图表/标题行等）
    func monitorRowInsets() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }

    /// List 首个 Section 内 segmented Picker 行（监控/进程/告警/证书详情切换器）
    func segmentedPickerRow() -> some View {
        listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }
}

// MARK: - 详情卡操作按钮

/// 详情页/服务卡内的操作按钮：图标 + 标题 + 淡色底块。
/// ServiceStatusCard 与防火墙/容器/应用/网站详情页的操作行共用此样式。
struct CardActionButton: View {
    let title: String
    let icon: String
    var color: Color = .accentColor
    /// 操作进行中：图标位置显示小进度圈
    var busy: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if busy {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(color)
                        .frame(width: 22, height: 22)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(disabled || busy)
    }
}

// MARK: - 可按压卡片样式

/// 入口卡按钮的按压反馈：轻微缩放 + 变暗（首页资源统计卡等）。
/// iPad 指针/触控板悬停高亮（触屏设备上 hoverEffect 自动无效）
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(Motion.fast, value: configuration.isPressed)
            .hoverEffect(.highlight)
    }
}

// MARK: - 跨组件导航通知（environment 无法穿透 navigationDestination 时的可靠方案）

extension Notification.Name {
    /// 请求 pop 应用详情页，回到应用列表
    static let popAppDetail = Notification.Name("1PanelClient.popAppDetail")
    /// 安装完成：pop 回应用列表并刷新
    static let installCompleted = Notification.Name("1PanelClient.installCompleted")
}

// MARK: - 底部操作菜单（.sheet + presentationDetents，与 Fail2ban 弹窗风格一致）

/// 底部弹出操作菜单项
struct ActionMenuItem: Identifiable {
    let id = UUID()
    let title: String
    let icon: String?
    let color: Color
    let role: ActionRole?
    let action: () -> Void

    init(title: String, icon: String? = nil, color: Color = .accentColor, role: ActionRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.color = color
        self.role = role
        self.action = action
    }
}

enum ActionRole {
    case destructive
}

/// 底部操作菜单视图（配合 `.sheet` + `.presentationDetents` 使用）。
/// 全站统一不带底部取消按钮，关闭靠下拉（各调用点均已开启 drag indicator）。
/// 使用方式：
/// ```
/// .sheet(isPresented: $showSheet) {
///     ActionBottomSheet(title: "标题", items: [...]) { selectedItem = nil }
///     .bottomSheetDetents([.height(ActionBottomSheet.height(for: 3))])
///     .presentationDragIndicator(.visible)
/// }
/// ```
struct ActionBottomSheet: View {
    let title: String
    let items: [ActionMenuItem]
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .padding(.bottom, 8)

            Divider()

            ForEach(items) { item in
                Button {
                    // 先收 sheet，动作推迟到下一主线程周期再触发：动作常是再弹
                    // alert/sheet，与 sheet 关闭在同一事务并发是已知的偶发丢呈现
                    // 场景（与 EllipsisMenuPopup 的 onDismiss-先-执行 模式一致）
                    // Task 继承 MainActor（非发送任务），闭包捕获免 Sendable 检查
                    let act = item.action
                    onDismiss()
                    Task { @MainActor in act() }
                } label: {
                    HStack(spacing: 14) {
                        if let icon = item.icon {
                            Image(systemName: icon)
                                .foregroundStyle(item.color)
                                .frame(width: 24)
                        }
                        Text(item.title)
                            .foregroundStyle(item.role == .destructive ? .red : .primary)
                        Spacer()
                    }
                    .padding(.vertical, 15)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if item.id != items.last?.id {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        // iPad（呈现方 regular）上 detents 已被 bottomSheetDetents 退掉、只剩标准
        // 大模态：菜单只有两三行却占整幅，收紧为内容大小的居中小卡（类 popover 观感，
        // 且免掉逐调用点锚定 popover 的分支互换风险）；iPhone 半屏 sheet 不受影响
        .adaptiveMenuSizing()
    }

    /// 根据 items 数量计算 sheet 高度（标题区 + 菜单行；无取消行）
    static func height(for itemCount: Int) -> CGFloat {
        CGFloat(72 + itemCount * 52)
    }
}

/// ActionBottomSheet 的呈现尺寸适配：regular 下 presentationSizing(.fitted)
/// （内容多大画布多大），compact 保持原样（半屏贴底 + 按条目数算高）
private struct AdaptiveMenuSizingModifier: ViewModifier {
    @Environment(\.presenterHorizontalSizeClass) private var presenter

    func body(content: Content) -> some View {
        if presenter == .regular {
            content.presentationSizing(.fitted)
        } else {
            content
        }
    }
}

extension View {
    /// 操作菜单弹层的尺寸类适配（见 AdaptiveMenuSizingModifier）
    func adaptiveMenuSizing() -> some View {
        modifier(AdaptiveMenuSizingModifier())
    }
}

// MARK: - 行单击/长按互斥手势

/// 行交互手势：单击与长按互不误触（全站统一口径）。
/// Button/NavigationLink 在触摸抬起时仍会激活——长按触发半屏菜单后松手，
/// 菜单之上会再叠一次点击进入（导航/编辑），表现为误触。这里统一改为
/// tap 手势 + 抑制标记：长按触发后吞掉紧随的松手 tap；标记 0.6 秒自愈
/// （松手未产生 tap 时复位），避免吞掉下一次正常点击。
struct RowTapLongPressModifier: ViewModifier {
    var onTap: () -> Void
    var onLongPress: () -> Void
    /// 长按触发时是否带 selection 触觉（默认带，与全站长按菜单一致）
    var longPressHaptic: Bool = true

    @State private var suppressNextTap = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture {
                guard !suppressNextTap else {
                    suppressNextTap = false
                    return
                }
                onTap()
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    if longPressHaptic { Haptic.selection() }
                    suppressNextTap = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if suppressNextTap { suppressNextTap = false }
                    }
                    onLongPress()
                }
            )
    }
}

extension View {
    /// 行单击 + 长按（长按后松手不触发单击；见 RowTapLongPressModifier）
    func rowTapAndLongPress(onTap: @escaping () -> Void,
                            onLongPress: @escaping () -> Void,
                            longPressHaptic: Bool = true) -> some View {
        modifier(RowTapLongPressModifier(onTap: onTap, onLongPress: onLongPress,
                                         longPressHaptic: longPressHaptic))
    }
}
