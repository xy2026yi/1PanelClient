//
//  LogListViewModel.swift
//  1PanelClient
//
//  日志列表通用 VM：操作/访问/SSH 三个日志页共用（分页追加 + 代际防串 +
//  快照保留），经 PageVMStore 常驻——重访即时渲染上次数据、autoRefresh
//  静默刷新。请求差异（endpoint / 请求体 / 是否分页）由注入的 fetchPage
//  承载：非分页接口每次返回全量，loadMore 天然空转。
//

import Foundation
import Combine

@MainActor
final class LogListViewModel<Item: Decodable & Identifiable>: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoadingMore = false

    var hasMore: Bool { items.count < total }

    /// 列表代数：load() 替换列表时递增，追加页响应到达时与捕获值比对——
    /// 期间发生过任何重载即丢弃过期追加（用代数而非页码：页码归 1 后
    /// next==2==page+1 恒成立，首次翻页恰是页码判定的盲区）
    private var loadGeneration = 0
    private var page = 1
    private var total = 0
    private let pageSize: Int
    /// 取一页（页码从 1 起）：返回条目与总数
    private let fetchPage: (_ page: Int) async throws -> ([Item], Int)

    init(pageSize: Int = 100,
         fetchPage: @escaping (_ page: Int) async throws -> ([Item], Int)) {
        self.pageSize = pageSize
        self.fetchPage = fetchPage
    }

    func load() async {
        // 常驻 VM 的静默刷新语义：有快照时不清列表不转圈（页面退取消不算失败）
        isLoading = items.isEmpty
        do {
            let (list, cnt) = try await fetchPage(1)
            items = list
            total = cnt
            page = 1
            loadGeneration += 1
            errorMessage = nil
        } catch {
            // 页面退出取消不是失败：保留原快照、不写错误态（pop 转场期间
            // 取消错误写入会短暂渲染出「网络错误」）
            if !APIError.isCancellation(error) {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    /// 追加下一页（滚动到底触发；按 id 去重，防翻页期间新记录导致跨页重复）
    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let next = page + 1
        let gen = loadGeneration
        do {
            let (list, cnt) = try await fetchPage(next)
            // 期间列表已被重载（下拉刷新触发新代数）：丢弃过期追加
            guard gen == loadGeneration else { return }
            let existing = Set(items.map(\.id))
            let newItems = list.filter { !existing.contains($0.id) }
            if newItems.isEmpty {
                // 翻页间隙服务器侧数据变动，去重后零新增：total 收敛为已加载量
                total = items.count
                return
            }
            items += newItems
            total = cnt
            page = next
        } catch {
            // 追加失败不打断列表，下拉刷新可重试
        }
    }
}
