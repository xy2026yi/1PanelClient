//
//  APIEndpoint.swift
//  1PanelClient
//

import Foundation

/// 1Panel OpenAPI 接口路径定义
/// 基于 doc/1panel_api_doc.json Swagger 文档确认
enum APIEndpoint {
    // MARK: - 仪表盘监控
    case dashboardOS              // GET 操作系统基础信息（os/kernel/distro）
    case dashboardBase            // GET 完整系统信息+CPU+内存+资源统计
    case dashboardCurrent         // GET 实时监控数据（独立轮询用）
    case dashboardTopCPU          // GET CPU占用TOP进程
    case dashboardTopMem          // GET 内存占用TOP进程
    case settingsSearch           // POST 面板设置（含 systemVersion 面板版本）

    // MARK: - 系统设备信息（toolbox）
    case deviceBase               // POST 设备基础信息

    // MARK: - 容器
    case containersSearch         // POST 分页查询容器
    case containersListStats      // GET  容器运行时指标（CPU/内存，按 containerID）
    case containersDockerStatus   // GET  Docker 服务状态（isActive/isExist）
    case containersDockerOperate  // POST Docker 服务操作（start/stop/restart）
    case containersPrune          // POST 清理容器/镜像
    case containersImageAll       // GET  所有镜像列表
    case containersSearchLog      // GET  容器日志（SSE 流式）
    case containersOperate        // POST 单个容器操作（stop/start/restart/kill）
    case containersUpgrade        // POST 容器升级
    case containersListByImage    // POST 按镜像查询容器
    case containersInfo           // POST 容器详情配置
    case containersImageOptions   // GET  镜像选项（用于编辑/升级）
    case containersUpdate         // POST 更新容器配置

    // MARK: - 网站
    case websitesSearch           // POST 分页查询网站
    case websitesCreate           // POST 创建网站（一键部署/反向代理/...）
    case websitesCheck            // POST 创建前环境检查
    case websitesSSLSearch        // POST 获取 SSL 证书列表（用于创建时选择）
    case websitesDelete           // POST 删除网站（含选项）
    case websitesDetail           // GET  网站详情（:id 路径参数）
    case websitesNginxConfig      // GET  获取 nginx 配置（:id 路径参数）
    case websitesNginxUpdate      // POST 更新 nginx 配置
    case websitesLogRead          // POST 读取网站日志（access/error）
    case websitesHTTPSRead        // GET  获取 HTTPS 配置（:id 路径参数）
    case websitesHTTPSUpdate      // POST 更新 HTTPS 配置（:id 路径参数）
    case websitesProxiesList      // POST 获取反向代理列表
    case websitesProxiesUpdate    // POST 创建/编辑/删除反向代理
    case websitesProxiesFile      // POST 读取/保存反向代理源文

    // MARK: - SSL 证书（独立管理）
    case websitesSSLList          // POST 分页查询证书
    case websitesSSLDetail        // GET  证书详情（:id 路径参数）
    case websitesSSLUpload        // POST 上传证书（粘贴 / 服务器文件 / 文件上传）
    case websitesSSLDelete        // POST 删除证书
    case websitesSSLDownload      // POST 下载证书（返回压缩包）

    // MARK: - 计划任务
    case cronjobsSearch           // POST 分页查询计划任务
    case cronjobsCreate           // POST 创建计划任务
    case cronjobsHandle           // POST 手动执行计划任务
    case cronjobsDelete           // POST 删除计划任务
    case cronjobsRecords          // POST 查询计划任务执行记录
    case cronjobsGroups           // POST 查询计划任务分组
    case cronjobsBackups          // GET  备份账号列表
    case cronjobsUsers            // GET  系统用户列表
    case cronjobsScripts          // GET  内置脚本列表

    // MARK: - 数据库
    case databasesSearch          // POST 分页查询数据库

    // MARK: - 应用
    case appsInstalledSearch      // POST 已安装应用分页查询
    case appsInstalledOperate     // POST 操作已安装应用（启动/停止/重启/升级）
    case appsUpdateVersions      // POST 查询可用更新版本
    case appsInstall             // POST 安装应用
    case appsInstalledIgnore     // POST 忽略应用升级
    case appsIgnoredList         // GET  忽略升级列表
    case appsIgnoredCancel       // POST 取消忽略升级
    case appsInstalledDeleteCheck // GET 删除前检查（:installId 路径参数）
    case appsInstalledParams     // GET  获取已安装应用参数（:installId 路径参数）
    case appsInstalledParamsUpdate // POST 更新已安装应用参数（重建应用）

    // MARK: - 应用商店
    case appsStoreSearch         // POST 应用商店搜索
    case appsStoreDetail         // GET  按 key 获取应用详情
    case appsSyncRemote          // POST 同步远程应用商店
    case appsSyncLocal           // POST 同步本地已安装应用
    case appsIcon                // GET  应用图标（:appID 路径参数，返回二进制图片）

    var path: String {
        switch self {
        case .dashboardOS:           return "/api/v2/dashboard/base/os"
        case .dashboardBase:         return "/api/v2/dashboard/base/all/all"
        case .dashboardCurrent:      return "/api/v2/dashboard/current/all/all"
        case .dashboardTopCPU:       return "/api/v2/dashboard/current/top/cpu"
        case .dashboardTopMem:       return "/api/v2/dashboard/current/top/mem"
        case .settingsSearch:        return "/api/v2/core/settings/search"
        case .deviceBase:            return "/api/v2/toolbox/device/base"
        case .containersSearch:      return "/api/v2/containers/search"
        case .containersListStats:      return "/api/v2/containers/list/stats"
        case .containersDockerStatus:   return "/api/v2/containers/docker/status"
        case .containersDockerOperate:  return "/api/v2/containers/docker/operate"
        case .containersPrune:          return "/api/v2/containers/prune"
        case .containersImageAll:       return "/api/v2/containers/image/all"
        case .containersSearchLog:      return "/api/v2/containers/search/log"
        case .containersOperate:        return "/api/v2/containers/operate"
        case .containersUpgrade:        return "/api/v2/containers/upgrade"
        case .containersListByImage:    return "/api/v2/containers/list/byimage"
        case .containersInfo:           return "/api/v2/containers/info"
        case .containersImageOptions:   return "/api/v2/containers/image"
        case .containersUpdate:         return "/api/v2/containers/update"
        case .websitesSearch:        return "/api/v2/websites/search"
        case .websitesCreate:        return "/api/v2/websites"
        case .websitesCheck:         return "/api/v2/websites/check"
        case .websitesSSLSearch:     return "/api/v2/websites/ssl/search"
        case .websitesDelete:        return "/api/v2/websites/del"
        case .websitesDetail:        return "/api/v2/websites/:id"
        case .websitesNginxConfig:   return "/api/v2/websites/:id/config/openresty"
        case .websitesNginxUpdate:   return "/api/v2/websites/nginx/update"
        case .websitesLogRead:       return "/api/v2/files/read"
        case .websitesHTTPSRead:     return "/api/v2/websites/:id/https"
        case .websitesHTTPSUpdate:   return "/api/v2/websites/:id/https"
        case .websitesProxiesList:   return "/api/v2/websites/proxies"
        case .websitesProxiesUpdate: return "/api/v2/websites/proxies/update"
        case .websitesProxiesFile:   return "/api/v2/websites/proxies/file"
        case .websitesSSLList:       return "/api/v2/websites/ssl/search"
        case .websitesSSLDetail:     return "/api/v2/websites/ssl/:id"
        case .websitesSSLUpload:     return "/api/v2/websites/ssl/upload"
        case .websitesSSLDelete:     return "/api/v2/websites/ssl/del"
        case .websitesSSLDownload:   return "/api/v2/websites/ssl/download"
        case .cronjobsSearch:        return "/api/v2/cronjobs/search"
        case .cronjobsCreate:        return "/api/v2/cronjobs"
        case .cronjobsHandle:        return "/api/v2/cronjobs/handle"
        case .cronjobsDelete:        return "/api/v2/cronjobs/del"
        case .cronjobsRecords:       return "/api/v2/cronjobs/search/records"
        case .cronjobsGroups:        return "/api/v2/core/groups/search"
        case .cronjobsBackups:       return "/api/v2/backups/options"
        case .cronjobsUsers:         return "/api/v2/toolbox/device/users"
        case .cronjobsScripts:       return "/api/v2/cronjobs/script/options"
        case .databasesSearch:       return "/api/v2/databases/db/search"
        case .appsInstalledSearch:   return "/api/v2/apps/installed/search"
        case .appsInstalledOperate:  return "/api/v2/apps/installed/op"
        case .appsUpdateVersions:    return "/api/v2/apps/installed/update/versions"
        case .appsInstall:           return "/api/v2/apps/install"
        case .appsInstalledIgnore:   return "/api/v2/apps/installed/ignore"
        case .appsIgnoredList:       return "/api/v2/apps/ignored/detail"
        case .appsIgnoredCancel:     return "/api/v2/apps/ignored/cancel"
        case .appsInstalledDeleteCheck: return "/api/v2/apps/installed/delete/check/:installId"
        case .appsInstalledParams:   return "/api/v2/apps/installed/params/:installId"
        case .appsInstalledParamsUpdate: return "/api/v2/apps/installed/params/update"
        case .appsStoreSearch:       return "/api/v2/apps/search"
        case .appsStoreDetail:       return "/api/v2/apps/:key"
        case .appsSyncRemote:        return "/api/v2/apps/sync/remote"
        case .appsSyncLocal:         return "/api/v2/apps/sync/local"
        case .appsIcon:              return "/api/v2/apps/icon/:appID"
        }
    }

    var method: String {
        switch self {
        case .dashboardOS, .dashboardBase, .dashboardCurrent, .dashboardTopCPU, .dashboardTopMem,
             .appsIgnoredList, .appsStoreDetail,
             .appsInstalledDeleteCheck, .appsInstalledParams,
             .websitesDetail, .websitesNginxConfig, .websitesHTTPSRead,
             .websitesSSLDetail, .cronjobsBackups, .cronjobsUsers, .cronjobsScripts,
             .containersListStats, .containersDockerStatus, .containersImageAll,
             .containersImageOptions,
             .appsIcon:
            return "GET"
        default:
            return "POST"
        }
    }
}
