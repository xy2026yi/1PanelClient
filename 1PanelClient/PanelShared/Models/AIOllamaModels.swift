//
//  AIOllamaModels.swift
//  1PanelClient
//
//  本地模型 Ollama（/api/v2/ai/ollama）：模型分页列表 [推测：抓包缺失] /
//  拉取（带进度）/ 失败重试 / 删除（强制）/ 断开会话
//

import Foundation

/// POST /api/v2/ai/ollama/model/search 返回的模型项 [推测：字段未抓包，全设可选]
nonisolated struct AIOllamaModel: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let model: String?
    /// 服务端可能返回数字（字节）或字符串（如 ""），字符串仅接受纯数字
    let size: Double?
    /// 服务端格式化的大小文本（如 "4.7 GB"）
    let sizeText: String?
    /// pulling / running / failed 等
    let status: String?
    let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, model, size, sizeText, status, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        if let d = try? c.decode(Double.self, forKey: .size) {
            size = d
        } else if let s = try? c.decode(String.self, forKey: .size), let d = Double(s) {
            size = d
        } else {
            size = nil
        }
        sizeText = try c.decodeIfPresent(String.self, forKey: .sizeText)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }

    var displayName: String { model ?? name ?? "#" + String(id) }

    /// 大小展示：优先服务端文本，否则字节换算
    var displaySize: String {
        if let text = sizeText, !text.isEmpty { return text }
        guard let bytes = size, bytes > 0 else { return "-" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var isRunning: Bool { (status ?? "").lowercased() == "running" }
}

/// POST /api/v2/ai/ollama/model {name, taskID}
nonisolated struct AIOllamaModelCreateRequest: Encodable {
    let name: String
    let taskID: String
}

/// POST /api/v2/ai/ollama/model/recreate {name, taskID}
nonisolated struct AIOllamaModelRecreateRequest: Encodable {
    let name: String
    let taskID: String
}

/// POST /api/v2/ai/ollama/model/del {ids, forceDelete}
nonisolated struct AIOllamaModelDeleteRequest: Encodable {
    let ids: [Int]
    let forceDelete: Bool
}

/// POST /api/v2/ai/ollama/close {name}
nonisolated struct AIOllamaCloseRequest: Encodable {
    let name: String
}
