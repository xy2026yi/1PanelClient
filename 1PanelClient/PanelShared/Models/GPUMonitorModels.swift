//
//  GPUMonitorModels.swift
//  1PanelClient
//
//  GPU 监控（/api/v2/ai/gpu/*）：
//  实时快照 load（设备/驱动/进程）+ 历史序列 search（利用率/显存/温度/功耗）
//  基于 1Panel dev-v2 agent/utils/ai_tools（nvidia-smi -q -x 解析，另支持 NPU/XPU）；
//  设备字段多为带单位的字符串（"97 %" / "8192 MiB"），数值化在各 computed 完成
//

import Foundation

// MARK: - 实时快照

/// GET /api/v2/ai/gpu/load
nonisolated struct GPULoadInfo: Decodable {
    /// nvidia / npu / xpu 等
    let type: String?
    let cudaVersion: String?
    let driverVersion: String?
    let gpu: [GPUDeviceInfo]?
    let npu: [GPUDeviceInfo]?
    let xpu: [GPUDeviceInfo]?

    var allDevices: [GPUDeviceInfo] { (gpu ?? []) + (npu ?? []) + (xpu ?? []) }
}

/// 单个加速器设备（字段全为字符串，"[N/A]" 视为无值）
nonisolated struct GPUDeviceInfo: Decodable, Identifiable, Hashable {
    let index: String?
    let productName: String?
    let busID: String?
    let fanSpeed: String?
    let temperature: String?
    let performanceState: String?
    let powerDraw: String?
    let maxPowerLimit: String?
    let memUsed: String?
    let memTotal: String?
    let gpuUtil: String?
    let computeMode: String?
    let migMode: String?
    let processes: [GPUProcess]?

    var id: String { "\(index ?? "")#\(productName ?? "")" }
    var displayName: String {
        if let name = productName, !name.isEmpty { return name }
        return index.flatMap { "GPU \($0)" } ?? "GPU"
    }

    // MARK: 数值化

    var utilPercent: Double? { Self.number(in: gpuUtil) }
    var memUsedMiB: Double? { Self.number(in: memUsed) }
    var memTotalMiB: Double? { Self.number(in: memTotal) }
    var temperatureC: Double? { Self.number(in: temperature) }
    var powerDrawW: Double? { Self.number(in: powerDraw) }
    var maxPowerW: Double? { Self.number(in: maxPowerLimit) }
    var fanPercent: Double? { Self.number(in: fanSpeed) }

    var memPercent: Double? {
        guard let used = memUsedMiB, let total = memTotalMiB, total > 0 else { return nil }
        return min(used / total * 100, 100)
    }

    /// 从 "97 %" / "85.50 W" / "[N/A]" 中取第一段数值
    static func number(in text: String?) -> Double? {
        guard let text, !text.isEmpty, !text.contains("N/A") else { return nil }
        guard let m = text.range(of: #"-?\d+(?:\.\d+)?"#, options: .regularExpression) else { return nil }
        return Double(text[m])
    }
}

/// 设备上的占用进程
nonisolated struct GPUProcess: Decodable, Identifiable, Hashable {
    let pid: Int?
    let type: String?
    let processName: String?
    let usedMemory: String?

    var id: String { "\(pid ?? 0)#\(processName ?? "")" }
    var usedMemoryMiB: Double? { GPUDeviceInfo.number(in: usedMemory) }
}

// MARK: - 历史序列

/// POST /api/v2/ai/gpu/search 请求（按设备名圈定）
nonisolated struct GPUMonitorSearchRequest: Encodable {
    let productName: String
    let startTime: String   // ISO8601 毫秒，复用 MonitorDate.requestString
    let endTime: String
}

/// POST /api/v2/ai/gpu/search 响应（MonitorGPUData）：各数组按索引与 date 一一对应。
/// 服务端 Go float64 数组为主，但同项目存在字符串数组先例，逐字段兼容两种元素类型。
nonisolated struct GPUMonitorData: Decodable {
    let date: [String]?
    let gpuValue: [Double]?
    let temperatureValue: [Double]?
    let powerUsed: [Double]?
    let powerTotal: [Double]?
    let powerPercent: [Double]?
    let memoryUsed: [Double]?
    let memoryTotal: [Double]?
    let memoryPercent: [Double]?
    let speedValue: [Double]?
    let processCount: [Double]?

    private enum CodingKeys: String, CodingKey {
        case date
        case gpuValue, temperatureValue
        case powerUsed, powerTotal, powerPercent
        case memoryUsed, memoryTotal, memoryPercent
        case speedValue, processCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent([String].self, forKey: .date)
        gpuValue = Self.flex(c, .gpuValue)
        temperatureValue = Self.flex(c, .temperatureValue)
        powerUsed = Self.flex(c, .powerUsed)
        powerTotal = Self.flex(c, .powerTotal)
        powerPercent = Self.flex(c, .powerPercent)
        memoryUsed = Self.flex(c, .memoryUsed)
        memoryTotal = Self.flex(c, .memoryTotal)
        memoryPercent = Self.flex(c, .memoryPercent)
        speedValue = Self.flex(c, .speedValue)
        processCount = Self.flex(c, .processCount)
    }

    /// 数值数组兼容解码：[Double] 或纯数字 [String]；字段缺失/不可解析为 nil
    private static func flex(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [Double]? {
        if let d = try? c.decode([Double].self, forKey: key) { return d }
        if let s = try? c.decode([String].self, forKey: key) {
            return s.compactMap { Double($0) ?? GPUDeviceInfo.number(in: $0) }
        }
        return nil
    }
}
