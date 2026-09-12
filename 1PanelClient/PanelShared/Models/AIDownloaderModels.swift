//
//  AIDownloaderModels.swift
//  1PanelClient
//
//  模型下载器（/api/v2/xpack/model/downloader）：下载设置（GET/POST）/
//  已下载模型分页与删除 / 下载队列分页（cancel/retry/delete 记录未抓包）/
//  HuggingFace 与 ModelScope 仓库搜索、详情（模型卡 + 文件列表）与下载
//
//  抓包来源：logs/vLLM与下载器.md（2026-09-12）
//

import Foundation

// MARK: - 宽松数值解码

/// 服务端数字字段可能以 浮点 / 整数 / 纯数字字符串 返回
/// （AIOllamaModel.size 同款防御；容错只把「原本抛错」变成功，不影响正常返回）
private nonisolated enum ModelFlex {
    static func double<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Double? {
        (try? c.decode(Double.self, forKey: key))
            ?? (try? c.decode(Int.self, forKey: key)).map(Double.init)
            ?? (try? c.decode(String.self, forKey: key)).flatMap(Double.init)
    }

    static func int<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        (try? c.decode(Int.self, forKey: key))
            ?? (try? c.decode(Double.self, forKey: key)).map(Int.init)
            ?? (try? c.decode(String.self, forKey: key)).flatMap(Int.init)
    }
}

// MARK: - 仓库来源

/// 搜索 / 下载来源（HuggingFace 与 ModelScope 二选一）
nonisolated enum ModelRepoSource: String, CaseIterable, Identifiable {
    case huggingface
    case modelscope

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .huggingface: return "HuggingFace"
        case .modelscope: return "ModelScope"
        }
    }
}

/// 仓库搜索排序（下拉选项，rawValue 为接口参数）
nonisolated enum ModelRepoSort: String, CaseIterable, Identifiable {
    case downloads
    case trending
    case likes
    case created
    case updated

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .downloads: return L10n.t("下载最多")
        case .trending: return L10n.t("热门趋势")
        case .likes: return L10n.t("点赞最多")
        case .created: return L10n.t("最新创建")
        case .updated: return L10n.t("最近更新")
        }
    }
}

// MARK: - 设置

/// GET/POST /api/v2/xpack/model/downloader/settings（保存时全字段回传）
nonisolated struct ModelDownloaderSettings: Codable {
    var modelDir: String?
    var hfEndpoint: String?
    var hfToken: String?
    var modelScopeEndpoint: String?
    var modelScopeToken: String?
}

// MARK: - 已下载模型

/// POST /api/v2/xpack/model/downloader/local/search 返回项
nonisolated struct ModelLocalItem: Decodable, Identifiable, Hashable {
    let name: String
    let path: String?
    /// 字节数；HuggingFace 搜索结果里出现过 0，展示时回退格式化文本
    let size: Double?
    let sizeFormatted: String?
    let createdAt: String?

    var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name, path, size, sizeFormatted, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        path = try? c.decode(String.self, forKey: .path)
        size = ModelFlex.double(c, .size)
        sizeFormatted = try? c.decode(String.self, forKey: .sizeFormatted)
        createdAt = try? c.decode(String.self, forKey: .createdAt)
    }

    var displaySize: String {
        if let text = sizeFormatted, !text.isEmpty { return text }
        guard let bytes = size, bytes > 0 else { return "-" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// POST local/search 请求 {page, pageSize, info}
nonisolated struct ModelDownloaderPageRequest: Encodable {
    var page: Int = 1
    var pageSize: Int = 20
    var info: String = ""
}

/// POST local/delete {name}
nonisolated struct ModelLocalDeleteRequest: Encodable {
    let name: String
}

// MARK: - 下载任务

/// POST /api/v2/xpack/model/downloader/tasks/search 返回项（下载接口也返回同结构）
nonisolated struct ModelDownloadTask: Decodable, Identifiable, Hashable {
    let id: Int
    let source: String?
    let repoID: String?
    let revision: String?
    let modelName: String?
    let targetDir: String?
    /// Waiting / Downloading / Success / Failed 等
    let status: String?
    /// 0-100 整数
    let progress: Int?
    let totalSize: Double?
    let downloadedSize: Double?
    let errorMessage: String?
    let createdAt: String?
    let startedAt: String?
    let completedAt: String?
    let canCancel: Bool?
    let canRetry: Bool?
    let canRemoveRecord: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, source, repoID, revision, modelName, targetDir, status, progress
        case totalSize, downloadedSize, errorMessage
        case createdAt, startedAt, completedAt
        case canCancel, canRetry, canRemoveRecord
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        source = try? c.decode(String.self, forKey: .source)
        repoID = try? c.decode(String.self, forKey: .repoID)
        revision = try? c.decode(String.self, forKey: .revision)
        modelName = try? c.decode(String.self, forKey: .modelName)
        targetDir = try? c.decode(String.self, forKey: .targetDir)
        status = try? c.decode(String.self, forKey: .status)
        progress = ModelFlex.int(c, .progress)
        totalSize = ModelFlex.double(c, .totalSize)
        downloadedSize = ModelFlex.double(c, .downloadedSize)
        errorMessage = try? c.decode(String.self, forKey: .errorMessage)
        createdAt = try? c.decode(String.self, forKey: .createdAt)
        startedAt = try? c.decode(String.self, forKey: .startedAt)
        completedAt = try? c.decode(String.self, forKey: .completedAt)
        canCancel = try? c.decode(Bool.self, forKey: .canCancel)
        canRetry = try? c.decode(Bool.self, forKey: .canRetry)
        canRemoveRecord = try? c.decode(Bool.self, forKey: .canRemoveRecord)
    }

    var displayName: String {
        if let name = modelName, !name.isEmpty { return name }
        if let repo = repoID, !repo.isEmpty { return repo }
        return "#" + String(id)
    }

    var sourceDisplay: String {
        ModelRepoSource(rawValue: source ?? "")?.displayName ?? (source ?? "-")
    }

    var isActive: Bool {
        ["waiting", "downloading"].contains((status ?? "").lowercased())
    }

    var isFailed: Bool {
        ["failed", "error", "canceled", "cancelled"].contains((status ?? "").lowercased())
    }

    /// 进度详情："953.3 MB / 1.4 GB"；总量未知（=0）时只显示已下载
    var progressDetail: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let done = formatter.string(fromByteCount: Int64(max(0, downloadedSize ?? 0)))
        guard let total = totalSize, total > 0 else { return done }
        return done + " / " + formatter.string(fromByteCount: Int64(total))
    }
}

/// POST tasks/search 请求 {page, pageSize, info, status}
nonisolated struct ModelDownloaderTasksRequest: Encodable {
    var page: Int = 1
    var pageSize: Int = 20
    var info: String = ""
    var status: String = ""
}

/// POST cancel/retry/remove {id}（三个端点请求体一致，端点确认.md 2026-09-12 确认）
nonisolated struct ModelTaskIDRequest: Encodable {
    let id: Int
}

// MARK: - 仓库搜索与详情

/// POST hf|modelscope/search 返回项
nonisolated struct ModelRepoItem: Decodable, Identifiable, Hashable {
    let repoID: String
    let name: String?
    let downloads: Int?
    let likes: Int?
    let size: Double?
    let sizeFormatted: String?

    var id: String { repoID }

    private enum CodingKeys: String, CodingKey {
        case repoID, name, downloads, likes, size, sizeFormatted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repoID = try c.decode(String.self, forKey: .repoID)
        name = try? c.decode(String.self, forKey: .name)
        downloads = ModelFlex.int(c, .downloads)
        likes = ModelFlex.int(c, .likes)
        size = ModelFlex.double(c, .size)
        sizeFormatted = try? c.decode(String.self, forKey: .sizeFormatted)
    }

    var displaySize: String {
        if let text = sizeFormatted, !text.isEmpty { return text }
        guard let bytes = size, bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// "20.7M 下载 · 1597 赞" 用紧凑数字
    var downloadsCompact: String {
        guard let n = downloads, n > 0 else { return "-" }
        return n.formatted(.number.notation(.compactName))
    }
}

/// POST hf|modelscope/search 请求 {query, sort, page, pageSize}
nonisolated struct ModelRepoSearchRequest: Encodable {
    var query: String
    var sort: String = ModelRepoSort.downloads.rawValue
    var page: Int = 1
    var pageSize: Int = 50
}

/// POST hf|modelscope/info 与 download 请求 {repoID}
nonisolated struct ModelRepoRequest: Encodable {
    let repoID: String
}

/// POST hf|modelscope/info 返回（含模型卡 Markdown 原文与文件列表）
nonisolated struct ModelRepoDetail: Decodable {
    let repoID: String?
    let name: String?
    let downloads: Int?
    let likes: Int?
    let size: Double?
    let sizeFormatted: String?
    let modelCard: String?
    let files: [ModelRepoFile]?

    private enum CodingKeys: String, CodingKey {
        case repoID, name, downloads, likes, size, sizeFormatted, modelCard, files
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repoID = try? c.decode(String.self, forKey: .repoID)
        name = try? c.decode(String.self, forKey: .name)
        downloads = ModelFlex.int(c, .downloads)
        likes = ModelFlex.int(c, .likes)
        size = ModelFlex.double(c, .size)
        sizeFormatted = try? c.decode(String.self, forKey: .sizeFormatted)
        modelCard = try? c.decode(String.self, forKey: .modelCard)
        files = try? c.decode([ModelRepoFile].self, forKey: .files)
    }

    var displaySize: String {
        if let text = sizeFormatted, !text.isEmpty { return text }
        guard let bytes = size, bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

nonisolated struct ModelRepoFile: Decodable, Hashable, Identifiable {
    let name: String
    let size: Double?
    let sizeFormatted: String?

    var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name, size, sizeFormatted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        size = ModelFlex.double(c, .size)
        sizeFormatted = try? c.decode(String.self, forKey: .sizeFormatted)
    }

    var displaySize: String {
        if let text = sizeFormatted, !text.isEmpty { return text }
        guard let bytes = size, bytes > 0 else { return "-" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
