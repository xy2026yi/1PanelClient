//
//  Clam.swift
//  1PanelClient
//
//  ClamAV 病毒扫描（/toolbox/clam）：双服务状态 / 扫描规则 / 报告 / 配置与日志
//

import Foundation

/// POST /api/v2/toolbox/clam/base：ClamAV 与病毒库服务（FreshClam）状态
nonisolated struct ClamBase: Decodable {
    let version: String?
    let isActive: Bool
    let isExist: Bool
    let freshVersion: String?
    let freshIsActive: Bool?
    let freshIsExist: Bool?
}

/// 扫描规则分页查询
nonisolated struct ClamSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let orderBy: String
    let order: String
}

/// 扫描规则（/toolbox/clam/search 返回 items）
nonisolated struct ClamItem: Decodable, Identifiable, Hashable {
    let id: Int
    let createdAt: String?
    let name: String
    /// "Disable" / ""
    let status: String?
    let path: String
    /// 感染文件策略：none / remove / move / copy
    let infectedStrategy: String?
    /// 移动/复制策略的隔离目录
    let infectedDir: String?
    /// 上次扫描结果："Done" / ""
    let lastRecordStatus: String?
    /// 上次扫描时间："-" / 时间串
    let lastRecordTime: String?
    /// 定期扫描 cron（空 = 手动执行）
    let spec: String?
    /// 超时秒数
    let timeout: Int?
    let description: String?
    let alertCount: Int?
    let alertMethod: String?
}

/// 定期扫描周期对象：全字段提交（含未用字段），服务端按 specType 取用
nonisolated struct ClamSpecObj: Codable {
    /// perDay / perWeek / perMonth
    var specType: String
    var week: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int
}

/// 创建 / 更新扫描规则（POST /toolbox/clam、/toolbox/clam/update）。
/// 更新需回传原记录审计字段；创建仅提交表单字段
nonisolated struct ClamUpsertRequest: Encodable {
    // 更新时回传（创建为 nil 省略）
    var id: Int? = nil
    var createdAt: String? = nil
    var status: String? = nil
    var lastRecordStatus: String? = nil
    var lastRecordTime: String? = nil
    var description: String? = nil
    var alertCount: Int? = nil
    // 表单字段
    var infectedStrategy: String
    var infectedDir: String
    var specObj: ClamSpecObj
    /// 超时数值 + 单位（s / m / h），timeout 为换算后的秒数
    var timeoutItem: Int
    var timeoutUnit: String
    var hasAlert: Bool
    var alertMethodItems: [String]
    var alertTitle: String
    var name: String
    var path: String
    var timeout: Int
    var spec: String
    var alertMethod: String
    /// 定期扫描时为 true（抓包仅勾选定期时出现该字段）
    var hasSpec: Bool? = nil
}

/// 立即执行扫描（异步任务，进度走任务日志）
nonisolated struct ClamHandleRequest: Encodable {
    let id: Int
}

/// 服务操作：ClamAV 用 start/stop/restart，病毒库服务用 fresh-stop/fresh-start/fresh-restart
nonisolated struct ClamOperateRequest: Encodable {
    let operation: String
}

/// 删除规则；勾选「删除病毒文件」时 isDeleteFile = true
nonisolated struct ClamDeleteRequest: Encodable {
    let ids: [Int]
    var isDeleteFile: Bool? = nil
}

/// 扫描报告分页查询（时间为 ISO8601 毫秒 UTC 串）
nonisolated struct ClamRecordSearchRequest: Encodable {
    let page: Int
    let pageSize: Int
    let clamID: Int
    let status: String
    let startTime: String
    let endTime: String
}

/// 扫描报告行（/toolbox/clam/record/search 返回 items）
nonisolated struct ClamRecordItem: Decodable, Identifiable, Hashable {
    let id: Int
    let taskID: String?
    let startTime: String?
    /// 如 "0.000 sec (0 m 0 s)"
    let scanTime: String?
    let infectedFiles: String?
    let totalError: String?
    /// "Done" / ""
    let status: String?
    let message: String?
}

/// 读取配置 / 日志：name = clamd / freshclam / clamd-log / freshclam-log；
/// 配置全文 tail = "0"，日志尾行 tail = "200"。返回 data 直接是文本
nonisolated struct ClamFileSearchRequest: Encodable {
    let name: String
    let tail: String
}

/// 保存配置 {name, file}
nonisolated struct ClamFileUpdateRequest: Encodable {
    let name: String
    let file: String
}
