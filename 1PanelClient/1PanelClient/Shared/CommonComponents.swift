//
//  CommonComponents.swift
//  1PanelClient
//
//  跨页面复用的轻量公共组件
//

import SwiftUI

// MARK: - 信息行（详情页 key-value 列表）

struct InfoRow: View {
    let key: String
    let value: String

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

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2.bold())
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.caption2.bold())
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
/// - 非搜索态：正常标题 + 左上角关闭按钮(可选) + 右上角放大镜
/// - 搜索态：左=返回(退出搜索) / 中=输入框 / 右=取消，占据整行
struct SearchIconModifier: ViewModifier {
    @Binding var text: String
    @Binding var isSearching: Bool
    let title: String
    let prompt: String
    var showCloseButton: Bool = true
    var onClose: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .navigationTitle(isSearching ? "" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isSearching {
                    if showCloseButton {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                endSearch()
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                        }
                    }
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
                    if showCloseButton {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: onClose) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
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
        showCloseButton: Bool = true,
        onClose: @escaping () -> Void = {}
    ) -> some View {
        modifier(SearchIconModifier(
            text: text,
            isSearching: isSearching,
            title: title,
            prompt: prompt,
            showCloseButton: showCloseButton,
            onClose: onClose
        ))
    }
}

// MARK: - popDetail 环境值

/// 用于从详情页直接 pop 回列表页（操作 NavigationPath 而非依赖 dismiss）
private struct PopDetailKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var popDetail: (() -> Void)? {
        get { self[PopDetailKey.self] }
        set { self[PopDetailKey.self] = newValue }
    }
}

// MARK: - 跨组件导航通知（environment 无法穿透 navigationDestination 时的可靠方案）

extension Notification.Name {
    /// 请求 pop 应用详情页，回到应用列表
    static let popAppDetail = Notification.Name("1PanelClient.popAppDetail")
    /// 安装完成：pop 回应用列表并刷新
    static let installCompleted = Notification.Name("1PanelClient.installCompleted")
}
