//
//  WebsitesTab.swift
//  1PanelClient
//

import SwiftUI
import Combine

struct WebsitesTab: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var vm: WebsitesViewModel
    @State private var searchText = ""

    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: WebsitesViewModel(server: server))
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.websites.isEmpty {
                    ProgressView("加载中…")
                } else if vm.websites.isEmpty {
                    ContentUnavailableView(
                        "暂无网站",
                        systemImage: "globe",
                        description: Text(vm.errorMessage ?? "这台服务器上没有网站")
                    )
                } else {
                    websiteList
                }
            }
            .navigationTitle("网站")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "搜索域名")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await vm.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onChange(of: searchText) { _, newValue in
                Task { await vm.search(query: newValue) }
            }
        }
        .task { await vm.refresh() }
    }

    private var websiteList: some View {
        List {
            ForEach(vm.websites) { w in
                WebsiteRow(website: w)
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct WebsiteRow: View {
    let website: Website

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.title2)
                .foregroundStyle(.green)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(website.displayName)
                    .font(.body.bold())
                    .lineLimit(1)

                if let alias = website.alias, alias != website.displayName {
                    Text(alias)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    if let type = website.type, !type.isEmpty {
                        Label(type, systemImage: "tag")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let r = website.remark, !r.isEmpty {
                        Text("· \(r)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - ViewModel

@MainActor
final class WebsitesViewModel: ObservableObject {
    @Published var websites: [Website] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func refresh() async {
        await load(query: "")
    }

    func search(query: String) async {
        await load(query: query)
    }

    private func load(query: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let req = WebsiteSearchRequest(
            page: 1,
            pageSize: 100,
            name: query,
            websiteGroupID: nil,
            orderBy: "created_at",
            order: "null"
        )
        do {
            let resp: WebsiteListResponse = try await client.send(
                path: APIEndpoint.websitesSearch.path,
                body: req,
                as: WebsiteListResponse.self
            )
            self.websites = resp.items ?? []
        } catch let err as APIError {
            self.errorMessage = err.errorDescription
            self.websites = []
        } catch {
            self.errorMessage = error.localizedDescription
            self.websites = []
        }
    }
}
