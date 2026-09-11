//
//  Supervisor.swift
//  1PanelClient
//
//  进程守护 Supervisor（/hosts/tool/*）：安装/初始化状态 / 服务操作 /
//  守护进程管理（创建/编辑/重启/删除/源文/日志）/ 主配置
//

import Foundation

// MARK: - 状态

/// POST /api/v2/hosts/tool/status {"type":"supervisord"}
nonisolated struct SupervisorToolRequest: Encodable {
    let type: String
}

/// status 返回 data：{type, config}
nonisolated struct SupervisorStatus: Decodable {
    let type: String?
    let config: SupervisorConfig?
}

nonisolated struct SupervisorConfig: Decodable, Hashable {
    let configPath: String?
    let includeDir: String?
    let logPath: String?
    let isExist: Bool?
    /// true = 已安装但未初始化（面板需要先初始化接管 [include] 配置）；JSON 键 init
    let needsInitialization: Bool?
    let msg: String?
    let version: String?
    /// "running" / ""
    let status: String?
    let ctlExist: Bool?
    let serviceName: String?

    enum CodingKeys: String, CodingKey {
        case configPath, includeDir, logPath, isExist
        case needsInitialization = "init"
        case msg, version, status, ctlExist, serviceName
    }
}

// MARK: - 初始化 / 服务操作

/// POST /api/v2/hosts/tool/init
nonisolated struct SupervisorInitRequest: Encodable {
    let type: String
    let configPath: String
    let serviceName: String
}

/// POST /api/v2/hosts/tool/operate（Supervisor 服务启停）
nonisolated struct SupervisorServiceOperateRequest: Encodable {
    let type: String
    let operate: String
}

// MARK: - 守护进程

/// POST /api/v2/hosts/tool/supervisor/process（operate: create/update/restart/delete）
nonisolated struct SupervisorProcessRequest: Encodable {
    let operate: String
    let name: String
    var command: String? = nil
    var user: String? = nil
    var dir: String? = nil
    var numprocsNum: Int? = nil
    var numprocs: String? = nil
    var autoRestart: String? = nil
    var autoStart: String? = nil
    var environment: String? = nil
}

/// GET /api/v2/hosts/tool/supervisor/process 返回的守护进程项
nonisolated struct SupervisorProcessItem: Decodable, Identifiable, Hashable {
    let name: String
    let command: String?
    let user: String?
    let dir: String?
    let numprocs: String?
    let msg: String?
    /// 多进程时每个实例一条
    let status: [SupervisorProcessState]?
    /// "true" / "false"（字符串开关）
    let autoRestart: String?
    let autoStart: String?
    let environment: String?

    var id: String { name }

    /// 首个实例状态（单进程场景即进程状态）
    var primaryState: SupervisorProcessState? { status?.first }

    /// 字符串开关（"true"/"false"）转 Bool
    func isEnabled(_ flag: String?) -> Bool { flag == "true" }
}

/// 单个进程实例状态（supervisor 状态机：RUNNING/STOPPED/BACKOFF/FATAL/STARTING/EXITED）
nonisolated struct SupervisorProcessState: Decodable, Hashable {
    /// 如 "123:123_00"
    let name: String?
    let status: String?
    let pid: String?
    let uptime: String?
    let msg: String?

    enum CodingKeys: String, CodingKey {
        case name, status, uptime, msg
        case pid = "PID"
    }
}

// MARK: - 源文 / 日志文件操作

/// POST /api/v2/hosts/tool/supervisor/process/file/get {"name", "file":"config"}
nonisolated struct SupervisorFileGetRequest: Encodable {
    let name: String
    let file: String
}

/// POST /api/v2/hosts/tool/supervisor/process/file：
/// operate=update 保存源文（file="config"）；operate=clear 清空日志（file="out.log"/"err.log"）
nonisolated struct SupervisorProcessFileRequest: Encodable {
    let name: String
    let operate: String
    let file: String
    var content: String? = nil
}

/// POST /api/v2/files/read/supervisor?operateNode=local：进程日志 type="supervisor"、
/// name="<进程名>.out.log"/".err.log"；服务日志 type="supervisord"、name="supervisor"
nonisolated struct SupervisorLogReadRequest: Encodable {
    var id: Int? = nil
    let type: String
    let name: String
    let page: Int
    let pageSize: Int
    let latest: Bool
}

// MARK: - 主配置

/// POST /api/v2/hosts/tool/config/get {"type":"supervisord"} → {content}
nonisolated struct SupervisorConfigGetRequest: Encodable {
    let type: String
}

nonisolated struct SupervisorConfigContent: Decodable {
    let content: String?
}

/// POST /api/v2/hosts/tool/config/set
nonisolated struct SupervisorConfigSetRequest: Encodable {
    let type: String
    let content: String
}
