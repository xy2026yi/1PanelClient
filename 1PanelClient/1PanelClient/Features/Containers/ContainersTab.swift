//
//  ContainersTab.swift
//  1PanelClient
//

import SwiftUI
import Combine

struct ContainersTab: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var vm: ContainersViewModel
    @State private var searchText = ""

    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: ContainersViewModel(server: server))
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.containers.isEmpty {
                    ProgressView("加载中…")
                } else if vm.containers.isEmpty {
                    ContentUnavailableView(
                        "暂无容器",
                        systemImage: "shippingbox",
                        description: Text(vm.errorMessage ?? "这台服务器上没有容器")
                    )
                } else {
                    containerList
                }
            }
            .navigationTitle("容器")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "搜索容器名")
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

    private var containerList: some View {
        List {
            ForEach(vm.containers) { c in
                ContainerRow(container: c)
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct ContainerRow: View {
    let container: Container

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: container.stateIcon)
                .font(.title2)
                .foregroundStyle(Color(container.stateColor))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(container.displayName)
                    .font(.body.bold())
                    .lineLimit(1)

                Text(container.displayImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(container.state.capitalized, systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color(container.stateColor))
                    if let runTime = container.runTime {
                        Text("· \(runTime)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
final class ContainersViewModel: ObservableObject {
    @Published var containers: [Container] = []
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

        let req = ContainerSearchRequest(
            page: 1,
            pageSize: 100,
            name: query,
            state: "all",
            orderBy: "name",
            order: "ascending"
        )
        do {
            let resp: ContainerListResponse = try await client.send(
                path: APIEndpoint.containersSearch.path,
                body: req,
                as: ContainerListResponse.self
            )
            self.containers = resp.items ?? []
        } catch let err as APIError {
            self.errorMessage = err.errorDescription
            self.containers = []
        } catch {
            self.errorMessage = error.localizedDescription
            self.containers = []
        }
    }
}
