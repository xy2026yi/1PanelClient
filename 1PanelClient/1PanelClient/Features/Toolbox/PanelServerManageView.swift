//
//  PanelServerManageView.swift
//  1PanelClient
//
//  面板/服务器管理：重启面板（1panel）、重启服务器（system）。
//  高危操作，统一走「输入 立即重启 确认」半屏弹窗（样式与删除确认一致）。
//

import SwiftUI

// MARK: - 面板/服务器管理

struct PanelServerManageView: View {
    let server: ServerConfig

    /// 待确认的重启目标（非 nil 时弹出确认半屏）
    @State private var restartTarget: RestartTarget?
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var alertMessage: String?
    @State private var showAlert = false

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient(server: server)
    }

    /// 重启目标（rawValue 对应路径参数 :target）
    enum RestartTarget: String, Identifiable {
        case panel = "1panel"
        case system = "system"

        var id: String { rawValue }

        var title: String {
            self == .panel ? "重启面板" : "重启服务器"
        }

        /// 完成后的提示文案
        var successToast: String {
            self == .panel
                ? "重启指令已发送，面板服务正在重启，几秒后恢复"
                : "重启指令已发送，服务器将失联 1-2 分钟"
        }
    }

    var body: some View {
        List {
            Section {
                actionRow(.panel, subtitle: "重启 1Panel 面板服务，几秒后自动恢复")
                actionRow(.system, subtitle: "重启整个服务器，期间将失联 1-2 分钟")
            } header: {
                Text("重启操作")
            } footer: {
                Text("高危操作，需输入「立即重启」确认")
            }
        }
        .navigationTitle("面板/服务器管理")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $restartTarget) { target in
            RestartConfirmSheet(title: target.title) {
                Task { await restart(target) }
            }
        }
        .toastOverlay(message: $toastMessage)
        .alert("提示", isPresented: $showAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - 行

    private func actionRow(_ target: RestartTarget, subtitle: String) -> some View {
        Button {
            restartTarget = target
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title3)
                    .foregroundStyle(.red)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - 请求

    private func restart(_ target: RestartTarget) async {
        let path = APIEndpoint.dashboardSystemRestart.path
            .replacingOccurrences(of: ":target", with: target.rawValue)
        do {
            let _: EmptyResponse = try await client.send(path: path, as: EmptyResponse.self)
            showToast(target.successToast)
        } catch let err as APIError {
            alertMessage = "操作失败：\(err.errorDescription ?? "未知错误")"
            showAlert = true
        } catch {
            alertMessage = "操作失败：\(error.localizedDescription)"
            showAlert = true
        }
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { toastMessage = nil }
        }
    }
}

// MARK: - 重启确认弹窗（输入「立即重启」半屏，样式与删除确认一致）

struct RestartConfirmSheet: View {
    let title: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    private let confirmText = "立即重启"

    private var canConfirm: Bool {
        input.trimmingCharacters(in: .whitespaces) == confirmText
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("此操作不可恢复。如果确认操作，请手动输入 '\(confirmText)'。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("确认输入") {
                    TextField("请输入 \(confirmText)", text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认重启", role: .destructive) {
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
