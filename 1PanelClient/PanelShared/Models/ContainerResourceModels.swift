//
//  ContainerResourceModels.swift
//  1PanelClient
//
//  容器资源模型（logs/推荐实现-容器.md 抓包 2026-09-14）：
//  网络 / 存储卷（创建含 NFS）· 编排（列表/创建/更新/操作/校验）· 编排模板 · 清理
//

import Foundation

// MARK: - 通用

/// key=value 对（网络排除 IP auxAddress / 存储卷 options 共用形态）
nonisolated struct ContainerKVPair: Codable, Hashable, Identifiable {
    var key: String
    var value: String
    /// 行身份与内容分离：两行空白/同内容行不再撞 ForEach ID、删除不再误删同内容行；
    /// 不参与 JSON 编解码（CodingKeys 仅含 key/value）
    var rowID = UUID()

    var id: UUID { rowID }

    enum CodingKeys: String, CodingKey { case key, value }
}

/// 分页请求 {page,pageSize}（网络/存储卷/模板列表共用）
nonisolated struct ContainerPageRequest: Encodable {
    let page: Int
    let pageSize: Int
}

/// 按名删除 {names}（网络/存储卷共用）
nonisolated struct ContainerNamesDeleteRequest: Encodable {
    let names: [String]
}

/// POST /containers/rename {name,newName}
/// （仅 isFromApp=false 且 isFromCompose=false 的容器可重命名，抓包 2026-09-14）
nonisolated struct ContainerRenameRequest: Encodable {
    let name: String
    let newName: String
}

// ContainerPruneRequest 复用 Container.swift 既有定义
// （taskID/pruneType/withTagAll；pruneType：container/image/network/volume）

// MARK: - 网络

/// POST /containers/network/search 返回的网络
nonisolated struct ContainerNetwork: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let labels: [String]?
    let driver: String?
    let ipamDriver: String?
    let subnet: String?
    let gateway: String?
    let createdAt: String?
    let attachable: Bool?
}

/// POST /containers/network（创建；抓包 2026-09-14 全字段）
nonisolated struct ContainerNetworkCreateRequest: Encodable {
    let name: String
    let parentNetworkCard: String
    let labelStr: String
    let labels: [String]
    let optionStr: String
    let options: [String]
    let driver: String
    let ipv4: Bool
    let subnet: String
    let gateway: String
    let ipRange: String
    let auxAddress: [ContainerKVPair]
    let ipv6: Bool
    let subnetV6: String
    let gatewayV6: String
    let ipRangeV6: String
    let auxAddressV6: [ContainerKVPair]
}

// MARK: - 存储卷

/// POST /containers/volume/search 返回的存储卷
nonisolated struct ContainerVolume: Decodable, Identifiable, Hashable {
    let name: String
    let labels: [String]?
    let driver: String?
    let mountpoint: String?
    let createdAt: String?
    let options: [ContainerKVPair]?

    var id: String { name }
}

/// POST /containers/volume（创建；NFS 开启时 options 由地址/版本/挂载点推导）
nonisolated struct ContainerVolumeCreateRequest: Encodable {
    let name: String
    let driver: String
    let labelStr: String
    let labels: [String]
    var nfsStatus: String = "disable"
    var nfsAddress: String = ""
    var nfsVersion: String = "v4"
    var nfsMount: String = ""
    var nfsOption: String = "rw,noatime,rsize=8192,wsize=8192,tcp,timeo=14"
    let optionStr: String
    let options: [String]
}

// MARK: - 编排

/// POST /containers/compose/search 返回的编排
nonisolated struct ContainerCompose: Decodable, Identifiable, Hashable {
    let name: String
    let createdAt: String?
    let createdBy: String?
    let containerCount: Int?
    let runningCount: Int?
    let configFile: String?
    let workdir: String?
    let composeFileExists: Bool?
    let isPinned: Bool?
    let path: String?
    let containers: [ContainerComposeItem]?
    let env: String?

    var id: String { name }
}

nonisolated struct ContainerComposeItem: Decodable, Hashable, Identifiable {
    let containerID: String
    let name: String?
    let createTime: String?
    let state: String?
    let ports: [String]?

    var id: String { containerID }
}

/// POST /containers/compose/search {info,page,pageSize,excludeAppStore}
nonisolated struct ContainerComposeSearchRequest: Encodable {
    var info: String = ""
    let page: Int
    let pageSize: Int
    var excludeAppStore: Bool = false
}

/// 编排创建：from = edit（编辑）/ template（模板）/ path（路径）
/// （compose/test 与 compose 请求体同构，test 阶段 taskID 为空串）
nonisolated struct ContainerComposeUpsertRequest: Encodable {
    var taskID: String = ""
    var name: String = ""
    let dirName: String
    let from: String
    var path: String = ""
    var file: String = ""
    var template: Int? = nil
    var env: String = ""
    var forcePull: Bool = false
}

/// POST /containers/compose/update {taskID,name,path,detailPath,content,createdBy,env,forcePull}
nonisolated struct ContainerComposeUpdateRequest: Encodable {
    let taskID: String
    let name: String
    let path: String
    let detailPath: String
    let content: String
    let createdBy: String
    let env: String
    let forcePull: Bool
}

/// POST /containers/compose/operate {name,path,operation,withFile,force}
/// operation：up / stop / restart / rebuild / delete
nonisolated struct ContainerComposeOperateRequest: Encodable {
    let name: String
    let path: String
    let operation: String
    var withFile: Bool = false
    var force: Bool = false
}

/// POST /containers/inspect {id,type,detail} → data 为配置文件文本
nonisolated struct ContainerInspectRequest: Encodable {
    let id: String
    let type: String
    let detail: String
}

// MARK: - 编排模板

/// POST /containers/template/search 返回的编排模板
nonisolated struct ContainerTemplate: Decodable, Identifiable, Hashable {
    let id: Int
    let createdAt: String?
    let name: String?
    let description: String?
    let content: String?
}

/// POST /containers/template（创建）{name,content,description}
nonisolated struct ContainerTemplateCreateRequest: Encodable {
    let name: String
    let content: String
    let description: String
}

/// POST /containers/template/update（编辑；全字段回传，含 createdAt 原值）
nonisolated struct ContainerTemplateUpdateRequest: Encodable {
    let id: Int
    let createdAt: String
    let name: String
    let description: String
    let content: String
}

/// POST /containers/template/del {ids}
nonisolated struct ContainerTemplateDeleteRequest: Encodable {
    let ids: [Int]
}
