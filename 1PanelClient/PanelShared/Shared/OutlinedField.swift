//
//  OutlinedField.swift
//  1PanelClient
//
//  描边包裹式表单控件（Material Outlined 风格，依据 -installFormDemo 原型验证）：
//  - 空值未聚焦：标签以正文字号贴左垂直居中显示在框内（即占位）；
//  - 聚焦或有值：标签缩小为小字、中心横跨描边框顶线（背景截断边框线）；
//  - 结构为「顶部 13pt 缓冲 + 52pt 描边框」：标签始终在组件 bounds 内绘制，
//    Menu/列表按 bounds 裁剪不会截到标签（原型踩坑：offset 溢出绘制会被 Menu 裁掉）。
//  适用：新建流向导页（见 docs/outlined-form-adoption-assessment-2026-09.md）。
//

import SwiftUI

// MARK: - 描边框公共外观

/// 描边框 + 浮动标签的公共绘制：文本输入与菜单选择共用同一视觉
struct OutlinedShape<Content: View, Trailing: View>: View {
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
                    .accessibilityHidden(isFloating)

                // 浮动标签：小字横跨框顶线（背景截断边框线），左缩进嵌线
                Text(label)
                    .font(.system(size: 11, weight: isFocused ? .semibold : .regular))
                    .foregroundStyle(isFocused ? Color.accentColor : .secondary)
                    .padding(.horizontal, 5)
                    .background(Color(.systemGroupedBackground))
                    .offset(x: 10, y: -7)
                    .opacity(isFloating ? 1 : 0)
                    .accessibilityHidden(!isFloating)
            }
            .animation(.easeInOut(duration: 0.18), value: isFloating)
        }
    }
}

// MARK: - 描边文本输入框

/// 描边包裹式文本输入（含 SecureField 变体）
struct OutlinedTextField: View {
    let label: String
    /// 聚焦且空值时框内的格式提示（可选，区别于标签）
    var prompt: String? = nil
    @Binding var text: String
    var isSecure = false
    var keyboardType: UIKeyboardType = .default
    /// 机器值：禁用首字母自动大写与纠错（默认开）
    var machineValue = true

    @FocusState private var isFocused: Bool

    var body: some View {
        OutlinedShape(label: label, isFocused: isFocused, hasValue: !text.isEmpty,
                      trailing: { EmptyView() }) {
            fieldBody
                .keyboardType(keyboardType)
                .focused($isFocused)
                .modifier(OutlinedMachineValue(enabled: machineValue))
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
        } else {
            TextField("", text: $text)
        }
    }
}

// MARK: - 描边数值+单位输入

/// 描边包裹式数值输入：框内值居左、固定单位贴右（如「核」「MB」）
struct OutlinedUnitField: View {
    let label: String
    let unit: String
    @Binding var text: String

    @FocusState private var isFocused: Bool

    var body: some View {
        OutlinedShape(label: label, isFocused: isFocused, hasValue: !text.isEmpty,
                      trailing: {
            Text(unit)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }) {
            TextField("", text: $text)
                .keyboardType(.numberPad)
                .focused($isFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

// MARK: - 描边多行输入（短多行）

/// 表单级多行字段（如 IP 列表）：默认 5 行高（minHeight 兜底，内容超出自然增高），
/// 空态标签在框内首行贴左，有内容/聚焦标签浮到描边线上
struct OutlinedMultiLineField: View {
    let label: String
    /// 聚焦且空值时框内的格式提示（可选）
    var prompt: String? = nil
    @Binding var text: String

    @FocusState private var isFocused: Bool

    private var isFloating: Bool { isFocused || !text.isEmpty }

    private var borderColor: Color {
        if isFocused { return .accentColor }
        if !text.isEmpty { return .primary.opacity(0.35) }
        return .secondary.opacity(0.45)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 13)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isFocused ? 1.5 : 1)
                    // 默认 5 行（行高约 22）+ 上下内边距
                    .frame(minHeight: 134)

                TextEditor(text: $text)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                    .frame(minHeight: 134, alignment: .topLeading)
                    .focused($isFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                // 空态标签：首行贴左（与多行输入起点一致），浮动态隐藏
                Text(label)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .opacity(isFloating ? 0 : 1)
                    .accessibilityHidden(isFloating)
                    .allowsHitTesting(false)

                if isFocused, text.isEmpty, let prompt {
                    Text(prompt)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.top, 16)
                        .allowsHitTesting(false)
                }

                // 浮动标签：横跨框顶线（与单行框同视觉）
                Text(label)
                    .font(.system(size: 11, weight: isFocused ? .semibold : .regular))
                    .foregroundStyle(isFocused ? Color.accentColor : .secondary)
                    .padding(.horizontal, 5)
                    .background(Color(.systemGroupedBackground))
                    .offset(x: 10, y: -7)
                    .opacity(isFloating ? 1 : 0)
                    .accessibilityHidden(!isFloating)
                    .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.18), value: isFloating)
        }
    }
}

// MARK: - 描边时间框

/// 描边框内显示 HH:mm（不可键入），点击弹出底部轮盘时间选择、选定回填。
/// 时间格式靠键入极易出错，轮盘为 iOS 惯例且零格式错误
struct OutlinedTimeField: View {
    let label: String
    @Binding var date: Date

    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            OutlinedShape(label: label, isFocused: false, hasValue: true,
                          trailing: {
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }) {
                Text(Self.format(date))
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPicker) {
            NavigationStack {
                DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxHeight: 280)
                    .navigationTitle(label)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.t("好的")) { showPicker = false }
                        }
                    }
            }
            .presentationDetents([.height(360)])
        }
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 描边菜单选择器

/// 描边包裹式单选菜单（外观与文本输入一致，右侧 chevron）。
/// options 为选项值；显示名与值不同时传 optionLabels（值 → 显示名，
/// 如数据库服务值 mysql → 显示「本地 MySQL」），未命中回退值本身
struct OutlinedPicker: View {
    let label: String
    let options: [String]
    @Binding var selection: String
    var optionLabels: [String: String] = [:]

    private func display(_ option: String) -> String {
        optionLabels[option] ?? option
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(display(option), systemImage: "checkmark")
                    } else {
                        Text(display(option))
                    }
                }
            }
        } label: {
            OutlinedShape(label: label, isFocused: false, hasValue: true,
                          trailing: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }) {
                Text(display(selection))
                    .foregroundStyle(.primary)
            }
        }
    }
}

/// 机器值输入修饰（禁用首字母自动大写 + 纠错）
private struct OutlinedMachineValue: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } else {
            content
        }
    }
}
