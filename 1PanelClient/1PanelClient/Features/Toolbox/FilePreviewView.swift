//
//  FilePreviewView.swift
//  1PanelClient
//
//  文本文件预览：POST /files/content 读取 content 展示（等宽、可选中复制），
//  标题为文件名。支持扩展名见 FilesView.previewableExtensions。
//

import SwiftUI

// MARK: - 请求模型

struct FileContentRequest: Encodable {
    let path: String
    let expand: Bool
    let page: Int
    let pageSize: Int
    let isDetail: Bool
}

/// files/content 响应（仅取预览需要的字段）
struct FileContentResponse: Decodable {
    let path: String?
    let name: String?
    let content: String?
    let size: Int64?
    let mimeType: String?
}

// MARK: - 预览页

struct FilePreviewView: View {
    let server: ServerConfig
    let item: FileItem

    @State private var content: String?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, item: FileItem) {
        self.server = server
        self.item = item
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else if let errorMessage {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button(L10n.t("重试")) { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if let content, !content.isEmpty {
                ScrollView {
                    Text(content)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                ContentUnavailableView(
                    L10n.t("空文件"),
                    systemImage: "doc",
                    description: Text(L10n.t("该文件没有内容"))
                )
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let req = FileContentRequest(path: item.path, expand: true, page: 1, pageSize: 100, isDetail: false)
        do {
            let resp: FileContentResponse = try await client.send(
                path: APIEndpoint.filesContent.path, body: req,
                as: FileContentResponse.self
            )
            self.content = resp.content
            self.errorMessage = nil
        } catch {
            // 取消（离开页面时 .task 被取消）不是失败，不写错误态
            guard !APIError.isCancellation(error) else { return }
            self.errorMessage = error.localizedDescription
        }
    }
}
