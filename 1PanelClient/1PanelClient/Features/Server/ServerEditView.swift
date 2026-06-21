//
//  ServerEditView.swift
//  1PanelClient
//

import SwiftUI

struct ServerEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: ServerManager

    var editing: ServerConfig?

    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var testing = false
    @State private var testResult: TestResult?

    struct TestResult {
        let success: Bool
        let message: String
    }

    var body: some View {
        NavigationStack {
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(name.isEmpty || baseURL.isEmpty || apiKey.isEmpty)
                }
            }
            .onAppear { loadIfEditing() }
        }
    }

    private func loadIfEditing() {
        guard let s = editing else { return }
        name = s.name
        baseURL = s.baseURL
        apiKey = s.apiKey
    }

    private func save() {
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
