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
    case settingsUpgradeCheck     // GET  检查面板更新
    case settingsUpgrade          // POST 面板版本升级
    case settingsUpgradeReleases  // GET  版本更新日志列表

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
    case containersCreate         // POST 创建容器
    case containersNetwork        // GET  网络选项（创建容器用）
    case containersVolume         // GET  存储卷选项（创建容器用）
    case containersLimit          // GET  CPU/内存上限（创建容器用）

    // MARK: - 网站
    case websitesSearch           // POST 分页查询网站
    case websitesCreate           // POST 创建网站（一键部署/反向代理/...）
    case websitesCheck            // POST 创建前环境检查
    case websitesSSLSearch        // POST 获取 SSL 证书列表（用于创建时选择）
    case websitesDelete           // POST 删除网站（含选项）
    case websitesOperate          // POST 网站操作（start/stop）
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
    case websitesSSLCreate        // POST 申请证书
    case websitesSSLObtain        // POST 获取/重新申请证书
    case websitesSSLUpdate        // POST 更新证书（自动续签等）
    case websitesSSLLog           // POST 读取证书申请日志

    // MARK: - ACME 账户
    case websitesAcmeSearch       // POST 查询 Acme 账户列表
    case websitesAcmeCreate       // POST 创建 Acme 账户
    case websitesAcmeDelete       // POST 删除 Acme 账户

    // MARK: - DNS 账户
    case websitesDnsSearch        // POST 查询 DNS 账户列表
    case websitesDnsCreate        // POST 创建 DNS 账户
    case websitesDnsDelete        // POST 删除 DNS 账户

    // MARK: - OpenResty 全局配置
    case openrestyConfig          // GET  读取 OpenResty 主配置
    case openrestyFile            // POST 保存 OpenResty 主配置
    case openrestyReset           // POST 还原默认配置

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
    case scriptSearch             // POST 脚本库搜索（core/script/search）

    // MARK: - 防火墙
    case firewallBase             // POST 防火墙基础状态
    case firewallOperate          // POST 防火墙操作（start/stop/restart/ping）
    case firewallSearch           // POST 端口规则列表
    case firewallPort             // POST 创建端口规则
    case firewallBatch            // POST 批量删除端口规则
    case firewallUpdatePort       // POST 修改端口规则

    // MARK: - 数据库
    case databasesSearch          // POST 分页查询数据库(MySQL)
    case databasesPgSearch        // POST 分页查询数据库(PostgreSQL)
    case databasesFormatOptions   // POST 字符集/排序规则选项
    case databasesCreate          // POST 创建数据库
    case databasesDelCheck        // POST 删除前检查
    case databasesDel             // POST 删除数据库
    case databasesRemote          // POST 远程访问状态
    case databasesChangeAccess    // POST 修改访问权限/远程访问
    case databasesChangePassword  // POST 修改密码
    case databasesRedisCheck      // GET  Redis 状态检查
    case appsInstalledCheck       // POST 已安装应用检查(状态/端口)
    case appsInstalledConnInfo    // POST 已安装应用连接信息

    // MARK: - PostgreSQL 专用端点
    case databasesPgCreate        // POST 创建PG数据库
    case databasesPgPassword      // POST PG密码修改(服务级+数据库级)
    case databasesPgDelCheck      // POST PG删除前检查
    case databasesPgDel           // POST PG删除数据库
    case databasesPgPrivileges    // POST PG权限(超级用户)修改

    // MARK: - Redis 专用端点
    case databasesRedisPassword   // POST Redis密码修改

    // MARK: - 进程
    case processStop             // POST 结束指定进程

    // MARK: - Fail2ban
    case fail2banBase            // GET  基础配置
    case fail2banUpdate          // POST 修改单项配置 {key, value}
    case fail2banLoadConf        // GET  加载完整配置文本
    case fail2banUpdateByConf    // POST 保存完整配置文本 {file}
    case fail2banOperate         // POST 服务操作 {operation}
    case fail2banSearch          // POST 查询白/黑名单 {status}
    case fail2banOperateSSHD     // POST 增删IP {operate, ips}

    // MARK: - 文件
    case filesSearch             // POST 文件浏览 {path, expand, page, pageSize, showHidden}

    // MARK: - WAF
    case wafStatus               // GET  WAF状态
    case wafConfigGlobal         // GET  全局配置
    case wafConfigGlobalState    // POST 切换规则开关 {scope, state}
    case wafIPGroupSearch        // POST IP组搜索
    case wafIPGroupCreate        // POST IP组创建
    case wafIPGroupDelete        // POST IP组删除
    case wafIPGroupUpdate        // POST IP组编辑
    case wafRuleIPSearch         // POST IP规则搜索
    case wafRuleIPCreate         // POST IP规则创建
    case wafRuleIPDelete         // POST IP规则删除
    case wafRuleIPUpdate         // POST IP规则编辑/启禁

    // MARK: - WAF 通用规则 (URL / UA)
    case wafRuleCommonSearch     // POST 通用规则搜索 {scope, websiteID}
    case wafRuleCommonCreate     // POST 通用规则创建
    case wafRuleCommonUpdate     // POST 通用规则编辑/启禁
    case wafRuleCommonDelete     // POST 通用规则删除

    // MARK: - WAF 频率限制 / 位置更新
    case wafRuleCc               // POST CC/攻击/404 频率限制保存
    case wafLocationUpdate       // POST IP地址库/恶意IP组/蜘蛛IP池更新

    // MARK: - 文件管理
    case settingsBaseDir         // GET  基础目录
    case filesUserGroup          // POST 用户/用户组列表
    case filesCreate             // POST 创建文件/文件夹
    case filesDel                // POST 删除文件/文件夹
    case filesRename             // POST 重命名

    // MARK: - SSH 管理
    case sshOperate              // POST SSH服务操作(start/stop/restart/enable/disable)
    case sshSearch               // POST SSH基础配置查询
    case sshUpdate               // POST SSH单项配置修改
    case sshFile                 // POST SSH完整配置文件读取
    case sshFileUpdate           // POST SSH完整配置文件保存

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
    case appsServices            // GET  获取数据库服务列表（:type 路径参数，如 mysql/postgres）

    // MARK: - 任务日志（安装/卸载进度）
    case logsTaskRead            // POST 读取任务日志（轮询 taskID）
    case logsTaskCount           // GET  正在执行的任务数量

    var path: String {
        switch self {
        case .dashboardOS:           return "/api/v2/dashboard/base/os"
        case .dashboardBase:         return "/api/v2/dashboard/base/all/all"
        case .dashboardCurrent:      return "/api/v2/dashboard/current/all/all"
        case .dashboardTopCPU:       return "/api/v2/dashboard/current/top/cpu"
        case .dashboardTopMem:       return "/api/v2/dashboard/current/top/mem"
        case .settingsSearch:        return "/api/v2/core/settings/search"
        case .settingsUpgradeCheck:  return "/api/v2/core/settings/upgrade"
        case .settingsUpgrade:       return "/api/v2/core/settings/upgrade"
        case .settingsUpgradeReleases: return "/api/v2/core/settings/upgrade/releases"
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
        case .containersCreate:         return "/api/v2/containers"
        case .containersNetwork:        return "/api/v2/containers/network"
        case .containersVolume:         return "/api/v2/containers/volume"
        case .containersLimit:          return "/api/v2/containers/limit"
        case .websitesSearch:        return "/api/v2/websites/search"
        case .websitesCreate:        return "/api/v2/websites"
        case .websitesCheck:         return "/api/v2/websites/check"
        case .websitesSSLSearch:     return "/api/v2/websites/ssl/list"
        case .websitesDelete:        return "/api/v2/websites/del"
        case .websitesOperate:       return "/api/v2/websites/operate"
        case .websitesDetail:        return "/api/v2/websites/:id"
        case .websitesNginxConfig:   return "/api/v2/websites/:id/config/openresty"
        case .websitesNginxUpdate:   return "/api/v2/websites/nginx/update"
        case .websitesLogRead:       return "/api/v2/files/read/website?operateNode=local"
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
        case .websitesSSLCreate:     return "/api/v2/websites/ssl"
        case .websitesSSLObtain:     return "/api/v2/websites/ssl/obtain"
        case .websitesSSLUpdate:     return "/api/v2/websites/ssl/update"
        case .websitesSSLLog:        return "/api/v2/files/read/ssl"
        case .websitesAcmeSearch:    return "/api/v2/websites/acme/search"
        case .websitesAcmeCreate:    return "/api/v2/websites/acme"
        case .websitesAcmeDelete:    return "/api/v2/websites/acme/del"
        case .websitesDnsSearch:     return "/api/v2/websites/dns/search"
        case .websitesDnsCreate:     return "/api/v2/websites/dns"
        case .websitesDnsDelete:     return "/api/v2/websites/dns/del"
        case .openrestyConfig:       return "/api/v2/openresty"
        case .openrestyFile:         return "/api/v2/openresty/file"
        case .openrestyReset:        return "/api/v2/apps/installed/conf"
        case .cronjobsSearch:        return "/api/v2/cronjobs/search"
        case .cronjobsCreate:        return "/api/v2/cronjobs"
        case .cronjobsHandle:        return "/api/v2/cronjobs/handle"
        case .cronjobsDelete:        return "/api/v2/cronjobs/del"
        case .cronjobsRecords:       return "/api/v2/cronjobs/search/records"
        case .cronjobsGroups:        return "/api/v2/core/groups/search"
        case .cronjobsBackups:       return "/api/v2/backups/options"
        case .cronjobsUsers:         return "/api/v2/toolbox/device/users"
        case .cronjobsScripts:       return "/api/v2/cronjobs/script/options"
        case .scriptSearch:          return "/api/v2/core/script/search"
        case .firewallBase:          return "/api/v2/hosts/firewall/base"
        case .firewallOperate:       return "/api/v2/hosts/firewall/operate"
        case .firewallSearch:        return "/api/v2/hosts/firewall/search"
        case .firewallPort:          return "/api/v2/hosts/firewall/port"
        case .firewallBatch:         return "/api/v2/hosts/firewall/batch"
        case .firewallUpdatePort:    return "/api/v2/hosts/firewall/update/port"
        case .databasesSearch:       return "/api/v2/databases/search"
        case .databasesPgSearch:     return "/api/v2/databases/pg/search"
        case .databasesFormatOptions: return "/api/v2/databases/format/options"
        case .databasesCreate:       return "/api/v2/databases"
        case .databasesDelCheck:     return "/api/v2/databases/del/check"
        case .databasesDel:          return "/api/v2/databases/del"
        case .databasesRemote:       return "/api/v2/databases/remote"
        case .databasesChangeAccess: return "/api/v2/databases/change/access"
        case .databasesChangePassword: return "/api/v2/databases/change/password"
        case .databasesRedisCheck:   return "/api/v2/databases/redis/check"
        case .appsInstalledCheck:    return "/api/v2/apps/installed/check"
        case .appsInstalledConnInfo: return "/api/v2/apps/installed/conninfo"
        case .databasesPgCreate:     return "/api/v2/databases/pg"
        case .databasesPgPassword:   return "/api/v2/databases/pg/password"
        case .databasesPgDelCheck:   return "/api/v2/databases/pg/del/check"
        case .databasesPgDel:        return "/api/v2/databases/pg/del"
        case .databasesPgPrivileges: return "/api/v2/databases/pg/privileges"
        case .databasesRedisPassword: return "/api/v2/databases/redis/password"
        case .processStop:           return "/api/v2/process/stop"
        case .fail2banBase:          return "/api/v2/toolbox/fail2ban/base"
        case .fail2banUpdate:        return "/api/v2/toolbox/fail2ban/update"
        case .fail2banLoadConf:      return "/api/v2/toolbox/fail2ban/load/conf"
        case .fail2banUpdateByConf:  return "/api/v2/toolbox/fail2ban/update/byconf"
        case .fail2banOperate:       return "/api/v2/toolbox/fail2ban/operate"
        case .fail2banSearch:        return "/api/v2/toolbox/fail2ban/search"
        case .fail2banOperateSSHD:   return "/api/v2/toolbox/fail2ban/operate/sshd"
        case .filesSearch:           return "/api/v2/files/search"
        case .wafStatus:             return "/api/v2/xpack/waf/status"
        case .wafConfigGlobal:       return "/api/v2/xpack/waf/config/global"
        case .wafConfigGlobalState:  return "/api/v2/xpack/waf/config/global/state"
        case .wafIPGroupSearch:      return "/api/v2/xpack/waf/ip/group/search"
        case .wafIPGroupCreate:      return "/api/v2/xpack/waf/ip/group/create"
        case .wafIPGroupDelete:      return "/api/v2/xpack/waf/ip/group/delete"
        case .wafIPGroupUpdate:      return "/api/v2/xpack/waf/ip/group/update"
        case .wafRuleIPSearch:       return "/api/v2/xpack/waf/rule/ip/search"
        case .wafRuleIPCreate:       return "/api/v2/xpack/waf/rule/ip/create"
        case .wafRuleIPDelete:       return "/api/v2/xpack/waf/rule/ip/delete"
        case .wafRuleIPUpdate:       return "/api/v2/xpack/waf/rule/ip/update"
        case .wafRuleCommonSearch:   return "/api/v2/xpack/waf/rule/common/search"
        case .wafRuleCommonCreate:   return "/api/v2/xpack/waf/rule/common/create"
        case .wafRuleCommonUpdate:   return "/api/v2/xpack/waf/rule/common/update"
        case .wafRuleCommonDelete:   return "/api/v2/xpack/waf/rule/common/delete"
        case .wafRuleCc:             return "/api/v2/xpack/waf/rule/cc"
        case .wafLocationUpdate:     return "/api/v2/xpack/waf/location/update"
        case .settingsBaseDir:       return "/api/v2/settings/basedir"
        case .filesUserGroup:        return "/api/v2/files/user/group"
        case .filesCreate:           return "/api/v2/files"
        case .filesDel:              return "/api/v2/files/del"
        case .filesRename:           return "/api/v2/files/rename"
        case .sshOperate:            return "/api/v2/hosts/ssh/operate"
        case .sshSearch:             return "/api/v2/hosts/ssh/search"
        case .sshUpdate:             return "/api/v2/hosts/ssh/update"
        case .sshFile:               return "/api/v2/hosts/ssh/file"
        case .sshFileUpdate:         return "/api/v2/hosts/ssh/file/update"
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
        case .appsServices:          return "/api/v2/apps/services/:type"
        case .logsTaskRead:          return "/api/v2/logs/tasks/read"
        case .logsTaskCount:         return "/api/v2/logs/tasks/executing/count"
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
             .containersImageOptions, .containersNetwork, .containersVolume, .containersLimit,
             .appsIcon, .databasesRedisCheck,
             .appsServices,
             .logsTaskCount,
             .fail2banBase, .fail2banLoadConf,
             .wafStatus, .wafConfigGlobal,
             .settingsBaseDir,
             .settingsUpgradeCheck, .settingsUpgradeReleases,
             .openrestyConfig:
            return "GET"
        default:
            return "POST"
        }
    }
}
