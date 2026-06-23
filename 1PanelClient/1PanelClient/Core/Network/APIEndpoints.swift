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
    case dashboardTopCPU          // GET CPU占用TOP进程
    case dashboardTopMem          // GET 内存占用TOP进程

    // MARK: - 系统设备信息（toolbox）
    case deviceBase               // POST 设备基础信息

    // MARK: - 登录配置（公开接口）
    case loginSetting

    // MARK: - 容器
    case containersSearch         // POST 分页查询容器

    // MARK: - 网站
    case websitesSearch           // POST 分页查询网站
    case websitesCreate           // POST 创建网站（一键部署/反向代理/...）
    case websitesCheck            // POST 创建前环境检查
    case websiteDir               // GET  获取网站默认根目录
    case websitesSSLSearch        // POST 获取 SSL 证书列表（用于创建时选择）
    case websitesDelete           // POST 删除网站（含选项）
    case websitesDetail           // GET  网站详情（:id 路径参数）
    case websitesNginxConfig      // GET  获取 nginx 配置（:id 路径参数）
    case websitesNginxUpdate      // POST 更新 nginx 配置
    case websitesLogRead          // POST 读取网站日志（access/error）

    // MARK: - 数据库
    case databasesSearch          // POST 分页查询数据库

    // MARK: - 文件
    case filesSearch              // POST 文件搜索

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

    var path: String {
        switch self {
        case .dashboardOS:           return "/api/v2/dashboard/base/os"
        case .dashboardBase:         return "/api/v2/dashboard/base/all/all"
        case .dashboardTopCPU:       return "/api/v2/dashboard/current/top/cpu"
        case .dashboardTopMem:       return "/api/v2/dashboard/current/top/mem"
        case .deviceBase:            return "/api/v2/toolbox/device/base"
        case .loginSetting:          return "/api/v2/core/auth/setting"
        case .containersSearch:      return "/api/v2/containers/search"
        case .websitesSearch:        return "/api/v2/websites/search"
        case .websitesCreate:        return "/api/v2/websites"
        case .websitesCheck:         return "/api/v2/websites/check"
        case .websiteDir:            return "/api/v2/files/path/websiteDir"
        case .websitesSSLSearch:     return "/api/v2/websites/ssl/search"
        case .websitesDelete:        return "/api/v2/websites/del"
        case .websitesDetail:        return "/api/v2/websites/:id"
        case .websitesNginxConfig:   return "/api/v2/websites/:id/config/openresty"
        case .websitesNginxUpdate:   return "/api/v2/websites/nginx/update"
        case .websitesLogRead:       return "/api/v2/files/read"
        case .databasesSearch:       return "/api/v2/databases/db/search"
        case .filesSearch:           return "/api/v2/files/search"
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
        }
    }

    var method: String {
        switch self {
        case .dashboardOS, .dashboardBase, .dashboardTopCPU, .dashboardTopMem,
             .loginSetting, .appsIgnoredList, .appsStoreDetail,
             .appsInstalledDeleteCheck, .appsInstalledParams, .websiteDir,
             .websitesDetail, .websitesNginxConfig:
            return "GET"
        default:
            return "POST"
        }
    }
}
