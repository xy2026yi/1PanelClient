//
//  ServerEditView.swift
//  1PanelClient
//

import SwiftUI

struct ServerEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: ServerManager

    var editing: ServerConfig?
    /// true = 以 sheet 弹出（自带 NavigationStack + 取消按钮）；false = 页面推入（返回即取消）
    var presentedAsSheet: Bool = true

    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var testing = false
    @State private var testResult: TestResult?
    @State private var showPlainHTTPWarning = false
    @AppStorage(SecurityGate.httpsOnlyKey) private var httpsOnly = false

    struct TestResult {
        let success: Bool
        let message: String
    }

    /// 输入中的地址是否为 http:// 明文（含协议省略时的默认行为见 normalizedBaseURL）
    private var draftIsPlainHTTP: Bool {
        ServerConfig(id: UUID(), name: name, baseURL: baseURL, apiKey: apiKey).isPlainHTTP
    }

    var body: some View {
        if presentedAsSheet {
            NavigationStack {
                form
            }
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section("服务器信息") {
                TextField("显示名称", text: $name)
                    .textInputAutocapitalization(.never)
                TextField("面板地址", text: $baseURL, prompt: Text("http://10.0.0.1:36130"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if draftIsPlainHTTP {
                    Label("HTTP 明文连接：API Key 与数据可能被链路窃听，建议改用 https://", systemImage: "lock.open")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    runTest()
                } label: {
                    HStack {
                        if testing {
                            ProgressView()
                        }
                        Text("测试连接")
                    }
                }
                .disabled(testing || baseURL.isEmpty || apiKey.isEmpty)

                if let r = testResult {
                    Label(r.message, systemImage: r.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(r.success ? .green : .red)
                        .font(.footnote)
                }
            }

            Section("提示") {
                Text("API Key 获取方式：面板 → 设置 → API 接口 → 开启并复制")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(editing == nil ? "添加服务器" : "编辑服务器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if presentedAsSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(name.isEmpty || baseURL.isEmpty || apiKey.isEmpty)
            }
        }
        .onAppear { loadIfEditing() }
        .confirmationDialog(
            "该面板使用 HTTP 明文连接",
            isPresented: $showPlainHTTPWarning,
            titleVisibility: .visible
        ) {
            Button("仍然保存", role: .destructive) { performSave() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("HTTP 明文连接下，API Key 与服务器数据可能被同一网络内的攻击者窃听或篡改。建议为面板配置 HTTPS 后再用 https:// 地址连接。")
        }
    }

    private func loadIfEditing() {
        guard let s = editing else { return }
        name = s.name
        baseURL = s.baseURL
        apiKey = s.apiKey
    }

    private func save() {
        if draftIsPlainHTTP {
            if httpsOnly {
                testResult = TestResult(
                    success: false,
                    message: "已开启「仅允许 HTTPS 连接」：请在 设置 → 安全 关闭该限制，或改用 https:// 地址"
                )
                return
            }
            showPlainHTTPWarning = true
            return
        }
        performSave()
    }

    private func performSave() {
        let s = ServerConfig(
            id: editing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if editing != nil { manager.update(s) } else { manager.add(s) }
        manager.select(s)
        dismiss()
    }

    private func runTest() {
        if draftIsPlainHTTP && httpsOnly {
            testResult = TestResult(
                success: false,
                message: "已开启「仅允许 HTTPS 连接」：请在 设置 → 安全 关闭该限制，或改用 https:// 地址"
            )
            return
        }
        testing = true
        testResult = nil
        let server = ServerConfig(
            id: editing?.id ?? UUID(),
            name: name,
            baseURL: baseURL,
            apiKey: apiKey
        )
        Task {
            let (ok, msg) = await ConnectionTester.test(server)
            await MainActor.run {
                self.testResult = TestResult(success: ok, message: msg)
                self.testing = false
            }
        }
    }
}
