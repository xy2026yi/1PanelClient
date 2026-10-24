//
//  ServerEditView.swift
//  1PanelClient
//
//  添加/编辑服务器：显示名称/面板地址/API Key（手动粘贴）+「登录并获取密钥」入口
//  （账号密码引导流在独立弹窗 ServerBootstrapView 内完成，取到的明文回填本表单）。
//  日常流量走 token 模式，本页只负责配置的录入与保存。
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
    @State private var showHTTPSBlockAlert = false
    @State private var httpsBlockMessage: String?
    @State private var showPlainHTTPWarning = false
    @AppStorage(SecurityGate.httpsOnlyKey) private var httpsOnly = false

    // 登录并获取密钥（引导弹窗）
    @State private var showBootstrap = false
    /// 引导成功后留档的安全入口码（下次引导免重填；保存时随服务器持久化）
    @State private var bootstrapEntranceCode = ""
    /// 引导成功的行内提示（用户改动 API Key 后消失）
    @State private var showKeyObtainedNote = false

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
            Section(L10n.t("服务器信息")) {
                OutlinedTextField(label: L10n.t("显示名称"), text: $name)
                OutlinedTextField(label: L10n.t("面板地址"), prompt: "http://10.0.0.1:36130",
                              text: $baseURL, keyboardType: .URL)
                OutlinedPasswordField(label: "API Key", text: $apiKey)
                if showKeyObtainedNote {
                    Label(L10n.t("已获取接口密钥，保存后即可以密钥连接"), systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
                if draftIsPlainHTTP {
                    Label(L10n.t("HTTP 明文连接：API Key 与数据可能被链路窃听，建议改用 https://"), systemImage: "lock.open")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    showBootstrap = true
                } label: {
                    Text(L10n.t("登录并获取密钥"))
                }
                .disabled(baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text(L10n.t("用面板账号密码自动获取接口密钥，无需到网页端手动复制；也可以直接粘贴已有 API Key。"))
            }

            Section {
                Button {
                    runTest()
                } label: {
                    HStack {
                        if testing {
                            ProgressView()
                        }
                        Text(L10n.t("测试连接"))
                    }
                }
                .disabled(testing || baseURL.isEmpty || apiKey.isEmpty)

                if let r = testResult {
                    Label(r.message, systemImage: r.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(r.success ? .green : .red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(editing == nil ? L10n.t("添加服务器") : L10n.t("编辑服务器"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .toolbar {
            if presentedAsSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.t("保存")) { save() }
                    .disabled(name.isEmpty || baseURL.isEmpty || apiKey.isEmpty)
            }
        }
        .onAppear { loadIfEditing() }
        .onChange(of: apiKey) { _, _ in
            showKeyObtainedNote = false
        }
        // 引导弹窗：地址用打开瞬间的快照，取到明文回填本表单
        .sheet(isPresented: $showBootstrap) {
            ServerBootstrapView(
                baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                initialEntranceCode: bootstrapEntranceCode
            ) { key, entrance in
                apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                bootstrapEntranceCode = entrance
                showKeyObtainedNote = true
            }
        }
        .alert(L10n.t("无法保存"), isPresented: $showHTTPSBlockAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(httpsBlockMessage ?? "")
        }
        .alert(L10n.t("该面板使用 HTTP 明文连接"), isPresented: $showPlainHTTPWarning) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("仍然保存"), role: .destructive) { Haptic.warning(); performSave() }
        } message: {
            Text(L10n.t("HTTP 明文连接下，API Key 与服务器数据可能被同一网络内的攻击者窃听或篡改。建议为面板配置 HTTPS 后再用 https:// 地址连接。"))
        }
    }

    // MARK: - 保存 / 测试

    private func loadIfEditing() {
        guard let s = editing else { return }
        name = s.name
        baseURL = s.baseURL
        apiKey = s.apiKey
        bootstrapEntranceCode = s.entranceCode ?? ""
    }

    private func save() {
        if draftIsPlainHTTP {
            if httpsOnly {
                // 显式弹窗提示（行内结果行小字在键盘弹起/滚动时易被忽略）
                httpsBlockMessage = L10n.t("已开启「仅允许 HTTPS 连接」：请在 设置 → 安全 关闭该限制，或改用 https:// 地址")
                showHTTPSBlockAlert = true
                testResult = TestResult(success: false, message: httpsBlockMessage ?? "")
                return
            }
            showPlainHTTPWarning = true
            return
        }
        performSave()
    }

    private func performSave() {
        let entrance = bootstrapEntranceCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = ServerConfig(
            id: editing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            // username 用完即清不落盘；安全入口码留档供下次引导免重填
            username: nil,
            entranceCode: entrance.isEmpty ? nil : entrance
        )
        if editing != nil { manager.update(s) } else { manager.add(s) }
        manager.select(s)
        dismiss()
    }

    private func runTest() {
        if draftIsPlainHTTP && httpsOnly {
            testResult = TestResult(
                success: false,
                message: L10n.t("已开启「仅允许 HTTPS 连接」：请在 设置 → 安全 关闭该限制，或改用 https:// 地址")
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
            // 草稿配置一次性探测，不进共享缓存（见 useSharedCache 参数注释）
            let (ok, msg) = await ConnectionTester.test(server, useSharedCache: false)
            await MainActor.run {
                self.testResult = TestResult(success: ok, message: msg)
                self.testing = false
            }
        }
    }
}
