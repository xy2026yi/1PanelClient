//
//  DebugInstallFormView.swift
//  1PanelClient
//
//  DEBUG 专用：安装表单交互原型（浮动标签输入框 + 三页向导）。
//  启动方式：模拟器带启动参数 -installFormDemo 拉起（见 _PanelClientApp.swift），Release 构建整体排除。
//
//  验证三件事：
//  1. OutlinedTextField（Material 风格描边输入框）：
//     - 空值未聚焦：标签以正文字号贴左显示在框内（即占位）；
//     - 聚焦或有值：标签缩小浮到描边上（截断边框线）；
//  2. 安装向导分页：名称/版本 → 参数 → 高级设置（默认关）；
//  3. 导航按钮固定底部（safeAreaInset，不随内容滚动）；步骤条带页名。
//

#if DEBUG
import SwiftUI

// MARK: - 通用描边框外观

/// 描边框 + 浮动标签的公共绘制：输入框与选择器共用同一视觉。
/// 组件 = 顶部 13pt 缓冲区 + 52pt 描边框：浮动标签画在框坐标系内、
/// 上移半个标签高使标签中心横跨框顶线（上半在线外、下半在线内，
/// 经典 Material 嵌线样式）；标签整体始终在组件 bounds 内，
/// Menu/列表按 bounds 裁剪不会截到标签
private struct DebugOutlinedShape<Content: View, Trailing: View>: View {
    let label: String
    let isFocused: Bool
    let hasValue: Bool
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    private var isFloating: Bool { isFocused || hasValue }
    /// 顶部缓冲区高度（≈ 半个浮动标签高，供标签压线时上半出框）
    private let floatArea: CGFloat = 13

    private var borderColor: Color {
        if isFocused { return .accentColor }
        if hasValue { return .primary.opacity(0.35) }
        return .secondary.opacity(0.45)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: floatArea)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isFocused ? 1.5 : 1)
                    .frame(height: 52)

                HStack {
                    content
                    Spacer(minLength: 0)
                    trailing
                }
                .padding(.horizontal, 14)
                .frame(height: 52, alignment: .center)

                // 空态标签：正文字号贴左、垂直居中（即占位），浮动态隐藏
                Text(label)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .frame(height: 52, alignment: .center)
                    .opacity(isFloating ? 0 : 1)

                // 浮动标签：小字横跨框顶线（背景截断边框线），左缩进嵌线
                Text(label)
                    .font(.system(size: 11, weight: isFocused ? .semibold : .regular))
                    .foregroundStyle(isFocused ? Color.accentColor : .secondary)
                    .padding(.horizontal, 5)
                    .background(Color(.systemGroupedBackground))
                    .offset(x: 10, y: -7)
                    .opacity(isFloating ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.18), value: isFloating)
        }
    }
}

// MARK: - 浮动标签描边输入框

struct DebugFloatingField: View {
    let label: String
    /// 聚焦且空值时框内的格式提示（可选，区别于标签）
    var prompt: String? = nil
    @Binding var text: String
    var isSecure = false
    var keyboardType: UIKeyboardType = .default

    @FocusState private var isFocused: Bool

    var body: some View {
        DebugOutlinedShape(label: label, isFocused: isFocused, hasValue: !text.isEmpty,
                           trailing: { EmptyView() }) {
            fieldBody
                .keyboardType(keyboardType)
                .focused($isFocused)
            if isFocused, text.isEmpty, let prompt {
                Text(prompt)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var fieldBody: some View {
        if isSecure {
            SecureField("", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } else {
            TextField("", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

// MARK: - 浮动标签描边选择器（Menu，外观与输入框一致）

struct DebugFloatingPicker: View {
    let label: String
    let options: [String]
    @Binding var selection: String

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            DebugOutlinedShape(label: label, isFocused: false, hasValue: true,
                               trailing: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }) {
                Text(selection)
                    .foregroundStyle(.primary)
            }
        }
    }
}

// MARK: - 安装向导原型页

struct DebugInstallFormView: View {
    /// 当前页：0 基础，1 配置，2 高级
    @State private var page = 0
    private let pageNames = [L10n.t("基础"), L10n.t("配置"), L10n.t("高级")]
    private let totalPages = 3

    // 第 1 页：基础
    @State private var installName = ""
    @State private var selectedVersion = "v1.29.2"

    // 第 2 页：配置
    @State private var webUIPort = ""

    // 第 3 页：高级
    @State private var advancedEnabled = false
    @State private var containerName = ""

    var body: some View {
        VStack(spacing: 0) {
            // 步骤指示：标题下方横贯（段线 + 页名），不进 toolbar
            stepIndicator
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 6)
            Form {
                Group {
                    switch page {
                    case 0: basicPage
                    case 1: paramsPage
                    default: advancedPage
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        // 底部固定导航：不随内容滚动
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .animation(.easeInOut(duration: 0.22), value: page)
        .navigationTitle(L10n.t("安装应用"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 步骤指示（页名 + 进度段，横贯内容区顶部）

    private var stepIndicator: some View {
        HStack(spacing: 10) {
            ForEach(0..<totalPages, id: \.self) { i in
                VStack(spacing: 5) {
                    Capsule()
                        .fill(i <= page ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                        .frame(maxWidth: .infinity)
                    Text(pageNames[i])
                        .font(.caption2.weight(i == page ? .bold : .regular))
                        .foregroundStyle(i <= page ? Color.accentColor : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: page)
    }

    // MARK: 第 1 页：名称 / 版本（每字段独立分组：浮动标签上抬空间不被相邻行遮挡）

    private var basicPage: some View {
        Group {
            Section {
                DebugFloatingField(label: L10n.t("名称"), prompt: "nginx-test", text: $installName)
            } footer: {
                Text(L10n.t("名称只能包含小写字母、数字和连字符"))
            }
            Section {
                DebugFloatingPicker(label: L10n.t("版本"),
                                    options: ["v1.29.2", "v1.28.0", "v1.27.4"],
                                    selection: $selectedVersion)
            }
        }
    }

    // MARK: 第 2 页：参数

    private var paramsPage: some View {
        Section {
            DebugFloatingField(label: L10n.t("Web UI 端口"), prompt: "18789",
                               text: $webUIPort, keyboardType: .numberPad)
        }
    }

    // MARK: 第 3 页：高级设置（默认关）

    private var advancedPage: some View {
        Group {
            Section {
                Toggle(L10n.t("高级设置"), isOn: $advancedEnabled)
            } footer: {
                Text(L10n.t("容器名、资源限制、重启规则等进阶项"))
            }
            if advancedEnabled {
                Section(L10n.t("容器")) {
                    DebugFloatingField(label: L10n.t("容器名称"), prompt: L10n.t("留空则自动生成"),
                                       text: $containerName)
                }
            }
        }
    }

    // MARK: 底部固定导航

    private var isLastPage: Bool { page == totalPages - 1 }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if page > 0 {
                Button(L10n.t("返回")) {
                    withAnimation { page -= 1 }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.4))
                )
            }
            Button {
                if isLastPage {
                    // 原型：仅演示完成态
                    print("[installFormDemo] install name=\(installName) version=\(selectedVersion) port=\(webUIPort) advanced=\(advancedEnabled)")
                } else {
                    withAnimation { page += 1 }
                }
            } label: {
                Text(isLastPage ? L10n.t("安装") : L10n.t("下一步"))
                    .bold()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(page == 0 && installName.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

#Preview("安装表单原型") {
    NavigationStack {
        DebugInstallFormView()
    }
}

#Preview("浮动输入框三态") {
    struct StatesDemo: View {
        @State private var empty = ""
        @State private var filled = "abc"
        @State private var version = "v1.29.2"
        var body: some View {
            Form {
                DebugFloatingField(label: L10n.t("容器名称"), prompt: "nginx-test", text: $empty)
                DebugFloatingField(label: L10n.t("容器名称"), prompt: "nginx-test", text: $filled)
                DebugFloatingPicker(label: L10n.t("版本"),
                                    options: ["v1.29.2", "v1.28.0"],
                                    selection: $version)
            }
        }
    }
    return StatesDemo()
}
#endif
