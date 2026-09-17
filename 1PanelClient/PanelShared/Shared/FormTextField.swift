//
//  FormTextField.swift
//  1PanelClient
//
//  表单输入行（标签常驻）：TextField/SecureField 的占位符只在空值时可见，
//  填入数据后字段失去标识。本组件把标签从占位符中拆出，任何时刻可见：
//    - .inline（默认）：左标签 + 右侧输入（与 InfoRow / 端口类行同构），适合短值
//    - .stacked：上标签 + 下输入（多行 / axis 输入自动使用），适合 URL、路径、密钥等长值
//  占位符职责随之分离：标签=字段是什么，prompt=怎么填（格式示例等，可选）。
//

import SwiftUI

struct FormTextField: View {
    enum FieldStyle {
        /// 左标签 + 右侧输入
        case inline
        /// 上标签 + 下输入
        case stacked
    }

    let label: String
    /// 输入提示（可选）：仅在空值时显示的占位符，如格式示例
    var prompt: String? = nil
    @Binding var text: String
    var style: FieldStyle = .inline
    var isSecure = false
    /// 多行增长输入；指定后自动使用 stacked 样式（inline 右对齐与多行不兼容）
    var axis: Axis? = nil
    var keyboardType: UIKeyboardType = .default
    /// 机器值（域名 / 密钥 / 路径 / 端口等）：禁用首字母自动大写与纠错，默认开启；
    /// 描述、备注等自然语言字段传 false
    var machineValue = true
    var disabled = false

    private var effectiveStyle: FieldStyle {
        axis != nil ? .stacked : style
    }

    var body: some View {
        switch effectiveStyle {
        case .inline:
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                Spacer(minLength: 12)
                fieldBody
                    .multilineTextAlignment(.trailing)
            }
        case .stacked:
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                fieldBody
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var fieldBody: some View {
        baseField
            .keyboardType(keyboardType)
            .disabled(disabled)
            .modifier(MachineValueTextModifiers(enabled: machineValue))
    }

    @ViewBuilder
    private var baseField: some View {
        if isSecure {
            SecureField(prompt ?? "", text: $text)
        } else if let axis {
            TextField(prompt ?? "", text: $text, axis: axis)
        } else {
            TextField(prompt ?? "", text: $text)
        }
    }
}

/// 机器值输入修饰（禁用首字母自动大写 + 纠错）
private struct MachineValueTextModifiers: ViewModifier {
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
