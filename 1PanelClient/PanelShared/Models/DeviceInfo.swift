//
//  DeviceInfo.swift
//  1PanelClient
//

import Foundation

/// 服务器设备基础信息（对应 /api/v2/toolbox/device/base）
/// 已通过 logs/输出7.log 验证字段格式
nonisolated struct DeviceInfo: Decodable, Sendable {
    let dns: [String]
    let hosts: [HostEntry]
    let hostname: String
    let timeZone: String
    let localTime: String
    let ntp: String?

    nonisolated struct HostEntry: Decodable, Sendable {
        let ip: String
        let host: String
    }
}
