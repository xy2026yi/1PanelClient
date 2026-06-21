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

    // MARK: - 数据库
    case databasesSearch          // POST 分页查询数据库

    // MARK: - 文件
    case filesSearch              // POST 文件搜索

    // MARK: - 应用
    case appsInstalledSearch      // POST 已安装应用分页查询
    case appsInstalledOperate     // POST 操作已安装应用（启动/停止/重启）
    case appsUpdateVersions      // POST 查询可用更新版本
    case appsInstall             // POST 安装/升级应用

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
        case .databasesSearch:       return "/api/v2/databases/db/search"
        case .filesSearch:           return "/api/v2/files/search"
        case .appsInstalledSearch:   return "/api/v2/apps/installed/search"
        case .appsInstalledOperate:  return "/api/v2/apps/installed/op"
        case .appsUpdateVersions:    return "/api/v2/apps/installed/update/versions"
        case .appsInstall:           return "/api/v2/apps/install"
        }
    }

    var method: String {
        switch self {
        case .dashboardOS, .dashboardBase, .dashboardTopCPU, .dashboardTopMem, .loginSetting:
            return "GET"
        default:
            return "POST"
        }
    }
}
