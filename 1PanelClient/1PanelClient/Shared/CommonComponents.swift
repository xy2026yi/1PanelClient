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
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: message)
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
}

// MARK: - 信息行（详情页 key-value 列表）

struct InfoRow: View {
    let key: String
    let value: String

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    /// 便捷初始化：`InfoRow("名称", value: x)`
    init(_ key: String, value: String) {
        self.key = key
        self.value = value
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
        .font(.subheadline)
    }
}

// MARK: - 可复制信息行（key-value + 一键复制）

/// 带复制按钮的信息行：与 InfoRow 同布局，右侧追加减号复制图标（连接信息等场景）。
struct CopyableInfoRow: View {
    let key: String
    let value: String

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    /// 便捷初始化：`CopyableInfoRow("端口", value: x)`
    init(_ key: String, value: String) {
        self.key = key
        self.value = value
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
        .font(.subheadline)
    }
}

// MARK: - 密码展示行（••• + 显示切换 + 复制）

/// 密码信息行：默认打码，可切换明文、一键复制。
/// 与 InfoRow 同级使用（数据库/用户详情等页面）；`compact: true` 用于嵌套的小字号行。
struct PasswordRow: View {
    var key: String = "密码"
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
                      ? .system(.caption, design: .monospaced)
                      : .system(.subheadline, design: .monospaced))
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
        HStack {
            if showPassword {
                TextField("密码", text: $password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
            } else {
                SecureField("密码", text: $password)
            }
            Button { showPassword.toggle() } label: {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            Button {
                password = Self.randomPassword()
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(.secondary)
            }
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
                .font(.system(.body, design: .monospaced))
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .accessibilityValue(isSelected ? "已选中" : "")
    }
}

// MARK: - 悬浮操作按钮（FAB）

/// 右下角悬浮操作按钮：默认 accent 色 + 号（56pt，阴影 r6·y4），配合 `.overlay(alignment: .bottomTrailing)` 使用。
/// 特殊入口（应用升级等）可换 systemImage / color。
struct FloatingActionButton: View {
    var systemImage: String = "plus"
    var color: Color = .accentColor
    /// VoiceOver 读出的操作描述（如「添加服务器」「创建数据库」）
    var accessibilityText: String = "添加"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(color, in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 4)
        }
        .accessibilityLabel(accessibilityText)
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }
}

/// FAB 的 Menu 变体：外观与 FloatingActionButton 完全一致，点击弹出菜单。
/// 用于「一个入口二选一」的创建场景，如「创建数据库 / 创建用户」「申请证书 / 上传证书」，
/// 避免把创建动作拆散到 toolbar Menu 里。
struct MenuFloatingActionButton<MenuItems: View>: View {
    var systemImage: String = "plus"
    var color: Color = .accentColor
    /// VoiceOver 读出的操作描述（如「创建」）
    var accessibilityText: String = "添加"
    @ViewBuilder let menuItems: () -> MenuItems

    var body: some View {
        Menu {
            menuItems()
        } label: {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(color, in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 4)
        }
        .accessibilityLabel(accessibilityText)
        .padding(.trailing, 20)
        .padding(.bottom, 20)
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
                .font(.system(size: size * 0.48, weight: .semibold))
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

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2.bold())
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
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
            }
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(.top, 48)
        .frame(maxWidth: .infinity)
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
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            endSearch()
                        } label: {
                            Text("取消")
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
        prompt: String
    ) -> some View {
        modifier(SearchIconModifier(
            text: text,
            isSearching: isSearching,
            title: title,
            prompt: prompt
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
    var fieldLabel: String = "确认输入"
    /// 输入框占位符，默认与确认文本一致
    var fieldPlaceholder: String?
    /// 确认按钮文案
    var confirmTitle: String = "删除"

    let onConfirm: () -> Void
    @ViewBuilder var options: () -> Options

    init(
        title: String,
        message: String,
        expectedText: String,
        fieldLabel: String = "确认输入",
        fieldPlaceholder: String? = nil,
        confirmTitle: String = "删除",
        onConfirm: @escaping () -> Void,
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
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle, role: .destructive) {
                        onConfirm()
                        dismiss()
                    }
                    .disabled(!canConfirm)
                }
            }
        }
        .presentationDetents([.medium])
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

// MARK: - 可按压卡片样式

/// 入口卡按钮的按压反馈：轻微缩放 + 变暗（首页资源统计卡等）
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
    case cancel
}

/// 底部操作菜单视图（配合 `.sheet` + `.presentationDetents` 使用）
/// 使用方式：
/// ```
/// .sheet(isPresented: $showSheet) {
///     ActionBottomSheet(title: "标题", items: [...]) { selectedItem = nil }
///     .presentationDetents([.height(ActionBottomSheet.height(for: 3))])
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
                    let act = item.action
                    act()
                    onDismiss()
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

                Divider()
            }

            Button {
                onDismiss()
            } label: {
                Text("取消")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    /// 根据 items 数量计算 sheet 高度
    static func height(for itemCount: Int) -> CGFloat {
        CGFloat(72 + itemCount * 52 + 52)
    }
}
