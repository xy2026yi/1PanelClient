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

    // 动态字体联动：字号/跨线偏移/缓冲区/框高随系统字号缩放，
    // 否则大字号下标签与描边线错位（相对 caption2/body 各自基准）
    @ScaledMetric(relativeTo: .caption2) private var floatFontSize: CGFloat = 11
    @ScaledMetric(relativeTo: .body) private var bodyFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var floatLift: CGFloat = 7
    @ScaledMetric(relativeTo: .caption2) private var floatArea: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var boxHeight: CGFloat = 52

    private var isFloating: Bool { isFocused || hasValue }

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
                    .frame(height: boxHeight)

                HStack {
                    content
                    Spacer(minLength: 0)
                    trailing
                }
                .padding(.horizontal, 14)
                .frame(height: boxHeight, alignment: .center)

                // 空态标签：正文字号贴左、垂直居中（即占位），浮动态隐藏
                Text(label)
                    .font(.system(size: bodyFontSize))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .frame(height: boxHeight, alignment: .center)
                    .opacity(isFloating ? 0 : 1)
                    .accessibilityHidden(isFloating)

                // 浮动标签：小字横跨框顶线（背景截断边框线），左缩进嵌线
                Text(label)
                    .font(.system(size: floatFontSize, weight: isFocused ? .semibold : .regular))
                    .foregroundStyle(isFocused ? Color.accentColor : .secondary)
                    .padding(.horizontal, 5)
                    .background(Color(.systemGroupedBackground))
                    .offset(x: 10, y: -floatLift)
                    .opacity(isFloating ? 1 : 0)
                    .accessibilityHidden(!isFloating)
            }
            .animation(.easeInOut(duration: 0.18), value: isFloating)
        }
    }
}

// MARK: - 描边文本输入框

/// 描边包裹式文本输入（密码场景用 OutlinedPasswordField）
struct OutlinedTextField: View {
    let label: String
    /// 聚焦且空值时框内的格式提示（可选，区别于标签）
    var prompt: String? = nil
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    /// 机器值：禁用首字母自动大写与纠错（默认开）
    var machineValue = true
    var disabled = false
    /// 框下方常驻提示（如格式示例/路径说明），始终显示
    var hint: String? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        fieldWithHint
    }

    private var fieldWithHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            OutlinedShape(label: label, isFocused: isFocused, hasValue: !text.isEmpty,
                          trailing: { EmptyView() }) {
            TextField("", text: $text)
                .keyboardType(keyboardType)
                .focused($isFocused)
                .disabled(disabled)
                .modifier(OutlinedMachineValue(enabled: machineValue))
            if isFocused, text.isEmpty, let prompt {
                Text(prompt)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }
        }
        if let hint {
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
        }
        }
    }
}

// MARK: - 描边密码框（眼睛切换）

/// 描边包裹式密码输入 + 框内右侧明文/密文切换眼睛。
/// 聚焦态由组件 FocusState 驱动（取代手包 OutlinedShape 固定 isFocused: false 的写法，
/// 那会导致聚焦时标签不上浮、边框不变色）。
/// 明密文为双字段叠放（不销毁重建）——条件 if/else 切换 TextField↔SecureField
/// 是两个视图身份，切换瞬间可能掉焦/键盘闪落；叠放共享同一绑定，切换不中断编辑
struct OutlinedPasswordField: View {
    let label: String
    /// 聚焦且空值时框内的格式提示（可选，区别于标签）
    var prompt: String? = nil
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default

    @State private var showPlain = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            OutlinedShape(label: label, isFocused: isFocused, hasValue: !text.isEmpty,
                          trailing: {
                Button {
                    showPlain.toggle()
                } label: {
                    Image(systemName: showPlain ? "eye.slash" : "eye")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // borderless：Form 行内多按钮默认样式会整行同触
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.t(showPlain ? "隐藏密码" : "显示密码"))
            }) {
                ZStack {
                    TextField("", text: $text)
                        .opacity(showPlain ? 1 : 0)
                        .allowsHitTesting(showPlain)
                        .focused($isFocused)
                    SecureField("", text: $text)
                        .opacity(showPlain ? 0 : 1)
                        .allowsHitTesting(!showPlain)
                        .focused($isFocused)
                }
                .keyboardType(keyboardType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            if isFocused, text.isEmpty, let prompt {
                Text(prompt)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - 描边数值+单位输入

/// 描边包裹式数值输入：框内值居左、固定单位贴右（如「核」「MB」）。
/// range 传入时输入即时钳制到范围（如原 Stepper 的 1...9999）
struct OutlinedUnitField: View {
    let label: String
    /// 框右侧常驻单位（如「核」「MB」）；无单位传空串
    let unit: String
    /// 空值时框内提示（如「可选」），有值自动隐藏
    var prompt: String? = nil
    @Binding var text: String
    var range: ClosedRange<Int>? = nil
    var keyboardType: UIKeyboardType = .numberPad
    /// 框下方常驻提示（如「如果设置为 0，则表示没有限制」）
    var hint: String? = nil
    /// 允许小数（如 CPU 核数 0.5）：跳过整数钳制，解析交给调用方（通常配 decimalPad）
    var allowsDecimal = false
    /// 失焦提交回调：numberPad 无回车键，onSubmit 不可达，靠失焦触发保存
    var onCommit: (() -> Void)? = nil

    @FocusState private var isFocused: Bool
    /// 编辑期显示镜像：允许临时空值/超范围中间态（输入中放宽），
    /// 失焦时归位到钳制后的模型值（解决「删空即回弹、无法重输」）
    @State private var display = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            OutlinedShape(label: label, isFocused: isFocused, hasValue: !display.isEmpty,
                          trailing: {
                Text(unit)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }) {
            TextField("", text: $display)
                .keyboardType(keyboardType)
                .focused($isFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                if display.isEmpty, let prompt, !isFocused {
                    Text(prompt)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
            }
        }
        .onAppear { display = text }
        // 非编辑期的外部回填/联动同步到显示；编辑期以显示为准（模型滞后到失焦归位）
        .onChange(of: text) { _, newValue in
            if !isFocused { display = newValue }
        }
        .onChange(of: display) { _, newValue in
            if allowsDecimal {
                // 小数路径：可解析为 Double 的中间态（含 "0."）写回模型；
                // 过渡空/非数字不写回，失焦统一归位（与整数路径语义一致）
                if Double(newValue) != nil {
                    text = newValue
                }
            } else if newValue.isEmpty {
                // 过渡空：不写回模型，失焦归位
            } else if let parsed = Int(newValue) {
                text = String(range.map { min(max(parsed, $0.lowerBound), $0.upperBound) } ?? parsed)
            } else {
                // 非数字字符：回退到当前模型值（保持纯数字输入）
                display = text
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                if !allowsDecimal {
                    if let parsed = Int(display) {
                        text = String(range.map { min(max(parsed, $0.lowerBound), $0.upperBound) } ?? parsed)
                    } else if range == nil {
                        // 无范围的数值字段允许清空 = 未设置（可选字段）
                        text = display
                    }
                    // 有范围且显示为空：保持模型最近有效值
                }
                display = text
                onCommit?()
            }
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
    /// 默认行数（minHeight 随之；内容超出自动增高），默认 5
    var lines: Int = 5
    /// 固定高度（行数）：内容超出框内滚动。nil = 随内容自然增高（旧行为）
    var fixedLines: Int? = nil
    /// 放大按钮：点击进入全屏编辑（实时绑定，返回即最新内容）
    var zoomable: Bool = false
    /// 全屏编辑用等宽字体（脚本/密钥类 true，普通文本 false）
    var monospaced: Bool = false
    @Binding var text: String

    @FocusState private var isFocused: Bool
    @State private var showZoom = false

    // 动态字体联动（默认 5 行 ≈ 行高 22 × 5 + 上下内边距，随 body 缩放）
    @ScaledMetric(relativeTo: .caption2) private var floatFontSize: CGFloat = 11
    @ScaledMetric(relativeTo: .body) private var bodyFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var floatLift: CGFloat = 7
    @ScaledMetric(relativeTo: .caption2) private var floatArea: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var bodyFont: CGFloat = 16
    /// 框高 = 浮动区 + 行数×行高 + 上下内边距（1 行约 60pt，文字不贴底边线）
    private var minHeight: CGFloat {
        floatArea + CGFloat(lines) * bodyFont * 1.45 + 24
    }

    /// 固定高度（fixedLines 锁定；TextEditor 内部为 UIScrollView，超高自动滚动）
    private var maxHeight: CGFloat? {
        fixedLines.map { floatArea + CGFloat($0) * bodyFont * 1.45 + 24 }
    }

    private var isFloating: Bool { isFocused || !text.isEmpty }

    private var borderColor: Color {
        if isFocused { return .accentColor }
        if !text.isEmpty { return .primary.opacity(0.35) }
        return .secondary.opacity(0.45)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: floatArea)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isFocused ? 1.5 : 1)
                    .frame(minHeight: minHeight, maxHeight: maxHeight)

                TextEditor(text: $text)
                    .font(.system(size: bodyFontSize))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                    .frame(minHeight: minHeight, maxHeight: maxHeight, alignment: .topLeading)
                    .focused($isFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                // 放大按钮：框右上角，进入全屏编辑
                if zoomable {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                isFocused = false
                                showZoom = true
                            } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.t("全屏编辑"))
                        }
                        Spacer()
                    }
                    .padding(.top, 2)
                    .padding(.trailing, 4)
                }

                // 空态标签：首行贴左（与多行输入起点一致），浮动态隐藏
                Text(label)
                    .font(.system(size: bodyFontSize))
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
                    .font(.system(size: floatFontSize, weight: isFocused ? .semibold : .regular))
                    .foregroundStyle(isFocused ? Color.accentColor : .secondary)
                    .padding(.horizontal, 5)
                    .background(Color(.systemGroupedBackground))
                    .offset(x: 10, y: -floatLift)
                    .opacity(isFloating ? 1 : 0)
                    .accessibilityHidden(!isFloating)
                    .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.18), value: isFloating)
        }
        // 全屏编辑（放大按钮进入；实时绑定，返回即最新内容）
        .fullScreenCover(isPresented: $showZoom) {
            FullscreenTextEditorSheet(title: label, text: $text, monospaced: monospaced)
        }
    }
}

// MARK: - 全屏文本编辑（OutlinedMultiLineField 放大进入）

/// 固定高度多行框的全屏编辑页：TextEditor 铺满 + 完成 + 行/字符统计；
/// 与小框共享同一绑定（实时同步，无保存/取消语义），键盘避让由 ScrollView 承担
struct FullscreenTextEditorSheet: View {
    let title: String
    @Binding var text: String
    var monospaced: Bool = false

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    private var lineCount: Int {
        max(1, text.split(whereSeparator: \.isNewline).count)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                TextEditor(text: $text)
                    .font(monospaced ? .body.monospaced() : .body)
                    // 隐藏编辑器自带背景：文字直接铺在页面底色上，
                    // 全屏与小框之间不再有割裂的框边界（无边全页书写）
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 420, alignment: .topLeading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .focused($isFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .scrollDisabled(true)   // 滚动交给外层，避免嵌套滚动手势冲突
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("完成")) { isFocused = false; dismiss() }
                        .bold()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text(L10n.f("%ld 行 · %ld 字", lineCount, text.count))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

// MARK: - 描边时间框

/// 描边框内显示 HH:mm（不可键入），点击弹出底部轮盘时间选择、选定回填。
/// 时间格式靠键入极易出错，轮盘为 iOS 惯例且零格式错误
struct OutlinedTimeField: View {
    let label: String
    @Binding var date: Date

    @State private var showPicker = false
    @ScaledMetric(relativeTo: .body) private var bodyFontSize: CGFloat = 16

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
                    .font(.system(size: bodyFontSize, design: .monospaced))
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

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func format(_ date: Date) -> String {
        formatter.string(from: date)
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

    /// 值/显示名分离版（自定义 init 会隐藏 memberwise，显式补回）
    init(label: String, options: [String], selection: Binding<String>,
         optionLabels: [String: String] = [:]) {
        self.label = label
        self.options = options
        self._selection = selection
        self.optionLabels = optionLabels
    }

    /// 枚举便利初始化：String-rawValue 枚举直接传入，display 提供显示名
    init<T: RawRepresentable>(label: String, options: [T],
                              selection: Binding<T>, display: @escaping (T) -> String)
    where T.RawValue == String {
        self.label = label
        self.options = options.map(\.rawValue)
        self._selection = Binding(
            get: { selection.wrappedValue.rawValue },
            set: { newValue in
                if let matched = options.first(where: { $0.rawValue == newValue }) {
                    selection.wrappedValue = matched
                }
            }
        )
        self.optionLabels = Dictionary(uniqueKeysWithValues: options.map {
            ($0.rawValue, display($0))
        })
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
