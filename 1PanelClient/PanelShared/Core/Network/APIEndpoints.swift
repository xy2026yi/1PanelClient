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
    case hostsMonitorSearch       // POST 历史监控查询 {param, io, network, startTime, endTime}
    case dashboardSystemRestart   // POST 重启面板/服务器（:target = 1panel / system）
    case dashboardTopCPU          // GET CPU占用TOP进程
    case dashboardTopMem          // GET 内存占用TOP进程
    case settingsSearch           // POST 面板设置（含 systemVersion 面板版本）
    case coreSettingsProxyUpdate  // POST 更新代理服务器（proxyType/Url/Port/User/Passwd/Keep）
    case settingsSearchPanel      // POST 面板设置·Web 端路径（含 firewallPortWhiteList 全量项；/core 变体部分版本不可用）
    case settingsUpdate           // POST 更新面板设置项 {key, value}（端口白名单等）
    case settingsUpgradeCheck     // GET  检查面板更新
    case settingsUpgrade          // POST 面板版本升级
    case settingsUpgradeReleases  // GET  版本更新日志列表

    // MARK: - 系统设备信息（toolbox）
    case deviceBase               // POST 设备基础信息
    case deviceCheckDns           // POST 测试 DNS 可用性（value 逗号拼接）
    case deviceUpdateConf         // POST 更新设备配置项 {key, value}（DNS/Ntp/LocalTime/Hostname/TimeZone）
    case deviceUpdateHost         // POST 覆盖提交 hosts 完整数组
    case deviceUpdatePasswd       // POST 修改系统密码 {user, passwd(base64)}
    case deviceZoneOptions        // GET  可选时区列表

    // MARK: - 缓存清理（toolbox）
    case toolboxScan              // POST 扫描可清理项（树形）
    case toolboxClean             // POST 清理勾选项 [{treeType, name, size}]

    // MARK: - 容器
    case containersSearch         // POST 分页查询容器
    case containersListStats      // GET  容器运行时指标（CPU/内存，按 containerID）
    case containersStats          // GET  单容器实时监控快照（:containerID 路径参数）
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
    case containersImagePull      // POST 拉取镜像
    case containersImageRemove    // POST 删除镜像（body: taskID + sha256 镜像 ID 列表）
    case containersRepoSearch     // POST 查询已配置的仓库
    case containersRepoCreate     // POST 添加镜像仓库
    case containersRepoUpdate     // POST 编辑镜像仓库
    case containersRepoDelete     // POST 删除镜像仓库 {id}
    case containersRepoSync       // POST 同步镜像仓库 {id}

    // MARK: - 网站
    case websitesSearch           // POST 分页查询网站
    case websitesCreate           // POST 创建网站（一键部署/反向代理/...）
    case websitesCheck            // POST 创建前环境检查
    case websitesSSLSearch        // POST 获取 SSL 证书列表（用于创建时选择）
    case websitesDelete           // POST 删除网站（含选项）
    case websitesUpdate           // POST 更新网站基础信息（主域名/备注）
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
    case websitesProxiesStatus    // POST 启用/停用反向代理
    case websitesConfig           // POST 读取网站配置（默认文档/流量限制）
    case websitesConfigUpdate     // POST 更新网站配置（默认文档/流量限制）
    case websitesRedirectList     // POST 获取重定向列表
    case websitesRedirectUpdate   // POST 创建/编辑/删除/启停重定向
    case websitesRedirectFile     // POST 保存重定向源文
    case websitesAuths            // POST 获取密码访问配置
    case websitesAuthsUpdate      // POST 创建/编辑/删除/启停密码访问账号
    case websitesDomains          // GET  获取网站域名列表（:id 路径参数）

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

    // MARK: - 自签证书（CA 机构）
    case websitesCaSearch         // POST 查询 CA 列表
    case websitesCaDetail         // GET  CA 详情（:id 路径参数）
    case websitesCaCreate         // POST 创建 CA
    case websitesCaDelete         // POST 删除 CA
    case websitesCaObtain         // POST 签发证书

    // MARK: - ACME 账户
    case websitesAcmeSearch       // POST 查询 Acme 账户列表
    case websitesAcmeCreate       // POST 创建 Acme 账户
    case websitesAcmeDelete       // POST 删除 Acme 账户

    // MARK: - DNS 账户
    case websitesDnsSearch        // POST 查询 DNS 账户列表
    case websitesDnsCreate        // POST 创建 DNS 账户
    case websitesDnsDelete        // POST 删除 DNS 账户
    case websitesDnsUpdate        // POST 更新 DNS 账户

    // MARK: - OpenResty 全局配置
    case openrestyConfig          // GET  读取 OpenResty 主配置
    case openrestyFile            // POST 保存 OpenResty 主配置
    case openrestyReset           // POST 还原默认配置
    case openrestyStatus          // GET  运行状态指标（活动连接/请求数等）
    case openrestyScope           // POST 读取性能参数（scope=http-per）
    case openrestyUpdate          // POST 保存性能参数
    case openrestyHttps           // GET/POST HTTPS 防窜站 / 拒绝默认SSL握手
    case openrestyModules         // GET  模块列表
    case openrestyModulesUpdate   // POST 开启/关闭模块（完整对象+operate）
    case openrestyBuild           // POST 构建模块（异步任务）

    // MARK: - 终端快速命令
    case commandsSearch           // POST 快速命令分页查询（type=command）
    case commandsCreate           // POST 创建快速命令
    case commandsUpdate           // POST 更新快速命令
    case commandsDelete           // POST 删除快速命令
    case commandGroupsSearch      // POST 命令分组查询（core/groups/search）

    // MARK: - 终端设置（默认连接 / 连接信息）
    case settingsSSHConn          // GET  默认连接状态 + 连接信息
    case settingsSSHDefault       // POST 默认连接开关
    case settingsSSHCheckInfo     // POST 连接信息测试
    case settingsSSHSave          // POST 保存连接信息

    // MARK: - 计划任务
    case cronjobsSearch           // POST 分页查询计划任务
    case cronjobsCreate           // POST 创建计划任务
    case cronjobsUpdate           // POST 更新计划任务
    case cronjobsLoadInfo         // POST 加载计划任务详情（编辑用）
    case cronjobsHandle           // POST 手动执行计划任务
    case cronjobsStatus           // POST 启用/停用计划任务
    case cronjobsDelete           // POST 删除计划任务
    case cronjobsRecords          // POST 查询计划任务执行记录
    case cronjobsBackups          // GET  备份账号列表
    case cronjobsUsers            // GET  系统用户列表
    case cronjobsScripts          // GET  内置脚本列表
    case scriptSearch             // POST 脚本库搜索（core/script/search）
    case scriptSync               // POST 立即同步系统脚本库（异步任务）
    case coreSettingsUpdate       // POST 更新面板设置项（core/settings/update）

    // MARK: - 分组（网站走 /api/v2/groups，计划任务/脚本走 /api/v2/core/groups，DTO 一致）
    case websitesGroupsSearch     // POST 网站分组查询 {type:"website"}
    case websitesGroupsCreate     // POST 创建网站分组
    case websitesGroupsUpdate     // POST 更新网站分组（isDefault=true 即设为默认）
    case websitesGroupsDelete     // POST 删除网站分组
    case coreGroupsSearch         // POST 计划任务/脚本分组查询
    case coreGroupsCreate         // POST 创建计划任务/脚本分组
    case coreGroupsUpdate         // POST 更新计划任务/脚本分组（isDefault=true 即设为默认）
    case coreGroupsDelete         // POST 删除计划任务/脚本分组

    // MARK: - 防火墙
    case firewallBase             // POST 防火墙基础状态
    case firewallOperate          // POST 防火墙操作（start/stop/restart/ping）
    case firewallSearch           // POST 端口规则列表
    case firewallPort             // POST 创建端口规则
    case firewallBatch            // POST 批量删除端口规则
    case firewallUpdatePort       // POST 修改端口规则
    case firewallForward          // POST 端口转发批量操作（add/remove，删除带 forceDelete）
    case firewallIP               // POST 创建 IP 规则
    case firewallUpdateAddr       // POST 修改 IP 规则
    case monitorNetOptions        // GET  网卡列表（端口转发的入站网口选择）

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

    // MARK: - MongoDB 专用端点
    case databasesMongoSearch         // POST 分页查询数据库(MongoDB)
    case databasesMongoCreate         // POST 创建 MongoDB 数据库
    case databasesMongoRootPassword   // POST MongoDB root 密码修改
    case databasesMongoPassword       // POST MongoDB 数据库密码修改
    case databasesMongoPrivilegesLoad // POST 查询 MongoDB 用户权限
    case databasesMongoPrivileges     // POST 修改 MongoDB 用户权限
    case databasesMongoDelCheck       // POST MongoDB 删除前检查
    case databasesMongoDel            // POST 删除 MongoDB 数据库

    // MARK: - MySQL 用户与授权管理
    case databasesUsersSearch     // POST 查询数据库用户列表
    case databasesGrantsSearch    // POST 查询用户关联数据库
    case databasesUsersCreate     // POST 创建数据库用户
    case databasesUsersDelete     // POST 删除数据库用户
    case databasesUsersUpdate     // POST 修改用户权限/描述
    case databasesUsersPassword   // POST 修改用户密码
    case databasesGrantsAdd       // POST 增加用户关联数据库
    case databasesGrantsDelete    // POST 移除用户关联数据库

    // MARK: - 进程
    case processStop             // POST 结束指定进程
    case processListening        // POST 端口监听进程列表（防火墙规则行显示进程名）

    // MARK: - Fail2ban
    case fail2banBase            // GET  基础配置
    case fail2banUpdate          // POST 修改单项配置 {key, value}
    case fail2banLoadConf        // GET  加载完整配置文本
    case fail2banUpdateByConf    // POST 保存完整配置文本 {file}
    case fail2banOperate         // POST 服务操作 {operation}
    case fail2banSearch          // POST 查询白/黑名单 {status}
    case fail2banOperateSSHD     // POST 增删IP {operate, ips}

    // MARK: - FTP（工具箱）
    case ftpBase                 // GET  安装/运行状态
    case ftpSearch               // POST 分页查询账号 {page, pageSize}
    case ftpCreate               // POST 创建账号 {user, password(base64), path, description?}
    case ftpUpdate               // POST 更新账号（全字段回传）
    case ftpOperate              // POST 服务操作 {operation}
    case ftpLogSearch            // POST 分页查询用户日志 {user, operation, page, pageSize}
    case ftpDelete               // POST 删除账号 {ids}
    case ftpSync                 // POST 同步账号

    // MARK: - ClamAV 病毒扫描（工具箱）
    case clamBase                // POST 安装/运行状态（ClamAV + FreshClam）
    case clamSearch              // POST 分页查询扫描规则 {page, pageSize, orderBy, order}
    case clamCreate              // POST 创建扫描规则
    case clamUpdate              // POST 更新扫描规则（全字段回传）
    case clamHandle              // POST 立即执行扫描 {id}
    case clamOperate             // POST 服务操作 {operation}（fresh- 前缀为病毒库服务）
    case clamDelete              // POST 删除规则 {ids[, isDeleteFile]}
    case clamRecordSearch        // POST 分页查询扫描报告
    case clamFileSearch          // POST 读取配置/日志 {name, tail}
    case clamFileUpdate          // POST 保存配置 {name, file}

    // MARK: - Supervisor 进程守护（工具箱）
    case supervisorStatus        // POST 安装/初始化状态 {type}
    case supervisorInit          // POST 初始化 {type, configPath, serviceName}
    case supervisorServiceOperate // POST 服务操作 {type, operate}
    case supervisorProcess       // POST 进程操作 {operate: create/update/restart/delete, ...}
    case supervisorProcessList   // GET  守护进程列表
    case supervisorProcessFileGet // POST 进程源文 {name, file:"config"}
    case supervisorProcessFile   // POST 保存源文 / 清空日志 {name, operate, file[, content]}
    case supervisorConfigGet     // POST 读取主配置 {type}
    case supervisorConfigSet     // POST 保存主配置 {type, content}
    case supervisorLogRead       // POST 进程/服务日志（files/read/supervisor）

    // MARK: - 告警通知
    case alertSearch            // POST 分页查询告警规则
    case alertCreate            // POST 创建告警规则
    case alertUpdate            // POST 更新告警规则
    case alertDelete            // POST 删除告警规则 {id}
    case alertLogsSearch        // POST 分页查询告警日志
    case alertDisksList         // GET  磁盘列表（磁盘告警选择挂载目录用）
    case alertConfigSearch      // POST 分页查询发送方式（excludeTypes 排除 sms）
    case alertConfigInfo        // POST 查询全部配置（含 common 全局配置）
    case alertConfigTest        // POST 测试发送方式（邮箱）
    case alertConfigUpdate      // POST 创建/更新发送方式与全局配置
    case alertConfigDelete      // POST 删除发送方式 {id}

    // MARK: - 文件
    case filesSearch             // POST 文件浏览 {path, expand, page, pageSize, showHidden}
    case filesUpload             // POST 上传文件（multipart: file+path+overwrite）
    case filesChunkUpload        // POST 分片上传（multipart: filename+path+chunk+chunkIndex+chunkCount，5MB/片）
    case filesDownload           // GET  下载文件（query: operateNode+path，返回二进制流）

    // MARK: - WAF
    case wafStatus               // GET  WAF状态
    case wafConfigGlobal         // GET  全局配置
    case wafConfigGlobalState    // POST 切换规则开关 {scope, state}
    case wafCdnUpdate            // POST CDN 真实 IP 获取方式更新 {rules, state, type, header, websiteID}
    case wafWebsitesSearch       // POST WAF 网站列表（含各网站 waf/strict/cc 状态）
    case wafWebsiteState         // POST 网站级开关/模式 {websiteID, scope, state[, mode]}
    case wafWebsiteRuleCC        // POST 网站级 CC 频率限制规则
    case wafConfigWebsite        // POST 网站配置详情 {id}（含 cc 真实参数，频率限制表单回填用）
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
    case wafRuleCommonApply      // POST 通用规则应用到网站 {scope, websites}

    // MARK: - WAF 频率限制 / 位置更新
    case wafRuleCc               // POST CC/攻击/404 频率限制保存
    case wafLocationUpdate       // POST IP地址库/恶意IP组/蜘蛛IP池更新
    case wafSpider               // POST 蜘蛛放行范围保存 {rules}

    // MARK: - WAF 监控
    case wafStat                 // GET  今日统计(请求/拦截/4xx/5xx)
    case wafStatDays             // GET  近7日统计(请求/拦截趋势)
    case wafLogSearch            // POST 拦截记录搜索
    case wafLogDetail            // GET  拦截记录详情(:id)
    case wafBlockSearch          // POST 封锁记录搜索

    // MARK: - 网站监控
    case monitorQps              // POST 实时 QPS/流量(1分钟)
    case monitorStat             // POST 今日/区间统计
    case monitorVisitors         // POST 访客趋势(折线)
    case monitorVisitorsLoc      // POST 访客地图(30日)
    case monitorRank             // POST 访问统计排行(uri/referer/ip/browser/os/device/status_code)
    case monitorLogsSearch       // POST 请求日志搜索
    case monitorLogsDetail       // POST 请求日志详情
    case wafLocationsWorld       // GET  地区名映射(英文→本地化,访客地图翻译用)

    // MARK: - 文件管理
    case settingsBaseDir         // GET  基础目录
    case filesUserGroup          // POST 用户/用户组列表
    case filesCreate             // POST 创建文件/文件夹
    case filesDel                // POST 删除文件/文件夹（forceDelete=false 进回收站）
    case filesRename             // POST 重命名
    case filesContent            // POST 读取文件内容（文本预览）
    case filesBatchCheck         // POST 上传前检查目标路径已存在文件
    case filesRecycleStatus      // GET  回收站启用状态（Enable/Disable）
    case filesRecycleSearch      // POST 回收站文件分页列表
    case filesRecycleReduce      // POST 回收站还原文件
    case filesRecycleClear       // POST 清空回收站

    // MARK: - SSH 管理
    case sshOperate              // POST SSH服务操作(start/stop/restart/enable/disable)
    case sshSearch               // POST SSH基础配置查询
    case sshUpdate               // POST SSH单项配置修改
    case sshFile                 // POST SSH完整配置文件读取
    case sshFileUpdate           // POST SSH完整配置文件保存
    case sshCertSearch           // POST SSH密钥列表
    case sshCertCreate           // POST 创建SSH密钥（generate/input/import）
    case sshCertUpdate           // POST 更新SSH密钥（名称/描述）
    case sshCertDelete           // POST 删除SSH密钥（可强制删除）
    case sshCertSync             // POST 同步SSH密钥（清理失效+同步新增）
    case disksList               // GET  磁盘总览（系统盘/未分区盘/数据盘）
    case disksPartition          // POST 立即分区（仅未分区磁盘）
    case disksMount              // POST 挂载分区
    case disksUnmount            // POST 取消挂载（按挂载点）

    // MARK: - SSH 连接主机
    case hostsSearch             // POST 分页查询已保存主机
    case hostsCreate             // POST 添加主机
    case hostsUpdate             // POST 更新主机
    case hostsDelete             // POST 删除主机 {ids}
    case hostsTestByInfo         // POST 按表单信息测试连通（添加/编辑时）
    case hostsTestByID           // POST 按已存 id 测试连通（连接前）
    case hostGroupsSearch        // POST 主机分组查询 {type:"host"}

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
    case appStoreSettingConfig   // GET  读取应用商店设置（卸载/升级/安装默认选项）
    case appStoreSettingUpdate   // POST 更新单项应用商店设置

    // MARK: - 应用商店
    case appsStoreSearch         // POST 应用商店搜索
    case appsStoreDetail         // GET  按 key 获取应用详情
    case appsTags                // GET  应用类别列表（商店/已安装应用共用，筛选传 key）
    case appsSyncRemote          // POST 同步远程应用商店
    case appsSyncLocal           // POST 同步本地已安装应用
    case appsIcon                // GET  应用图标（:appID 路径参数，返回二进制图片）
    case appsServices            // GET  获取数据库服务列表（:type 路径参数，如 mysql/postgres）

    // MARK: - 备份（应用 / 网站 / 数据库）
    case backupsLocal              // GET  备份存放目录
    case backupsRecordSearch       // POST 备份记录分页查询
    case backupsRecordSize         // POST 备份文件大小批量查询
    case backupsBackup             // POST 创建备份（压缩密码/描述/参数）
    case backupsRecover            // POST 恢复备份（超时/清空库等参数）
    case backupsRecordDelete       // POST 删除备份记录
    case backupsRecordDownload     // POST 获取备份文件下载路径

    // MARK: - 备份账号（MINIO / WebDAV / SFTP）
    case backupAccountsSearch      // POST 备份账号分页查询
    case backupAccountsBuckets     // POST 获取存储桶列表
    case backupAccountsCheck       // POST 连接测试
    case backupAccountsCreate      // POST 创建备份账号
    case backupAccountsUpdate      // POST 更新备份账号
    case backupAccountsDelete      // POST 删除备份账号

    // MARK: - 任务日志（安装/卸载进度）
    case logsTaskRead            // POST 读取任务日志（轮询 taskID）
    case logsTaskCount           // GET  正在执行的任务数量
    case logsTaskSearch          // POST 任务中心分页查询（管理-面板-任务中心）

    // MARK: - 日志模块
    case logsOperation           // POST 操作日志分页查询
    case logsLogin               // POST 访问日志（面板登录记录）分页查询
    case logsSystemFiles         // GET  系统日志日期列表
    case logsSSHLog              // POST SSH 登陆日志分页查询
    case logsWebsitesList        // GET  网站列表（网站日志下拉用）
    case logsReadSystem          // POST 读取系统日志行（files/read/system）
    case logsReadWebsite         // POST 读取网站日志行（files/read/website）

    // MARK: - 多机管理（专业版；社区版 nodes/current 会失败，需兜底）
    case nodesCurrent            // GET  全部节点实时状态（CPU/内存/健康）
    case nodesList               // POST 节点列表（含地址/分组/版本）
    case nodesTestByInfo         // POST 添加节点前可用性检查（byinfo）
    case nodesCreate             // POST 添加节点（异步任务，返回 taskID 日志）

    // MARK: - 许可证（专业版授权；0909 抓包）
    case licensesSearch          // POST 许可证分页列表
    case licensesUpload          // POST 上传授权文件（multipart）
    case licensesBind            // POST 绑定节点（syncList 固定四项同步）
    case licensesUnbind          // POST 解绑
    case licensesDel             // POST 删除（已绑定的需先解绑）
    case licensesSync            // POST 同步
    case licensesOptions         // POST 许可证选项列表（添加专业版节点用）
    case nodesSearch             // POST 节点详情分页查询（字段全，详情页/编辑用）
    case nodesUpdate             // POST 编辑节点（完整对象回传，异步任务）
    case nodesUpdateBase         // POST 轻量改名称（名称/分组/备注）
    case nodesSync               // POST 同步数据到节点（异步任务）
    case nodesRestart            // POST 重启节点面板/服务器（restartService）
    case nodesDelete             // POST 删除节点（force/withUninstall）
    case nodesUpgradeLogs        // POST 节点更新记录分页查询
    case nodeGroupsSearch        // POST 节点分组列表（type=node）

    // MARK: - AI 模块（logs/AI.md 抓包 2026-09-11；标 [推测] 的端点未抓到完整请求，按命名规律推定，联调时集中修正）
    // 模型账号
    case aiAccountsSearch       // POST 分页查询模型账号 [推测：抓包列表 URL 笔误]
    case aiAccountsCreate       // POST 创建模型账号（validateAvailability=true 时后端验证连通）
    case aiAccountsUpdate       // POST 更新模型账号（syncAgents 同步关联智能体）
    case aiAccountsDelete       // POST 删除模型账号 {id}（被智能体绑定时后端报错）
    case aiAccountProviders     // GET  预设供应商列表（含 apiTypes/预设模型）
    case aiAccountModelsDiscover // POST 发现远端模型 {provider, baseURL, apiKey, apiType}
    case aiAccountModelsList    // POST 账号模型池 {accountId}
    case aiAccountModelCreate   // POST 模型池添加 {accountId, model}
    case aiAccountModelUpdate   // POST 模型池编辑 {accountId, model}
    case aiAccountModelDelete   // POST 模型池删除 {accountId, recordId}（verifyModel 不可删）
    // 智能体
    case aiAgentsSearch         // POST 分页查询智能体 [推测：抓包列表 URL 笔误]
    case aiAgentsCreate         // POST 创建智能体（安装应用，带 taskID）
    case aiAgentsDeleteCheck    // POST 删除前检查绑定资源 {agentId}
    case aiAgentsDelete         // POST 删除智能体 {id, taskID, forceDelete}
    case aiAgentWebsiteBind     // POST 绑定网站 {agentId, websiteId}
    case aiAgentWebsiteUnbind   // POST 解绑网站 {agentId}
    case aiAgentModelGet        // POST 读取模型配置 {agentId}
    case aiAgentModelUpdate     // POST 保存模型配置 {agentId, accountId, model, fallbacks}
    case aiAgentSkillsSearch    // POST 技能市场搜索 {agentId, source, keyword}
    case aiAgentSkillsInstall   // POST 安装技能 {agentId, source, slug, taskID}
    case aiAgentSkillsList      // POST 已安装技能 {agentId}
    case aiAgentOtherGet        // POST 其他设置（时区/用户名/密码等）{agentId}
    case aiAgentOtherUpdate     // POST 保存其他设置
    case aiAgentConfigFileGet   // POST 读取配置文件 {agentId}
    case aiAgentChannelGet      // POST 频道配置读取（:type = weixin/qqbot/wecom/dingtalk/feishu/telegram/discord）
    case aiAgentChannelUpdate   // POST 频道配置保存 [推测：抓包缺失]
    case aiAgentWeixinLogin     // POST 微信扫码对接 {agentId}（任务日志中输出二维码 URL）
    case aiAgentChannelDelete   // POST 删除频道对接 {agentId, type}
    // MCP
    case aiMcpSearch            // POST 分页查询 MCP Server {page, pageSize, name}
    case aiMcpServerCreate      // POST 创建 MCP Server（带 taskID）
    case aiMcpServerUpdate      // POST 编辑 MCP Server（全字段回传，带 taskID）
    case aiMcpServerDelete      // POST 删除 MCP Server {id}
    case aiMcpServerOperate     // POST 启停/重启 {id, operate}
    case aiMcpStatusSync        // POST 批量同步状态 {ids}
    case aiMcpConnectionTest    // POST 测试连接 {id}
    case aiMcpDomainGet         // GET  MCP 域名绑定信息
    case aiMcpDomainBind        // POST MCP 绑定网站/域名
    case aiMcpDomainUpdate      // POST MCP 域名绑定更新（含 HTTPS）
    // 本地模型 Ollama
    case aiOllamaModelSearch    // POST Ollama 模型分页列表 [推测：抓包缺失]
    case aiOllamaModelCreate    // POST 拉取模型 {name, taskID}
    case aiOllamaModelRecreate  // POST 拉取失败重试 {name, taskID}
    case aiOllamaModelDelete    // POST 删除模型 {ids, forceDelete}
    case aiOllamaClose          // POST 断开运行中模型会话 {name}
    // Ollama AI 网关域名
    case aiDomainGet            // POST 网关域名信息 {appInstallID}
    case aiDomainBind           // POST 网关域名绑定
    case aiDomainUpdate         // POST 网关域名更新

    var path: String {
        switch self {
        case .dashboardOS:           return "/api/v2/dashboard/base/os"
        case .dashboardBase:         return "/api/v2/dashboard/base/all/all"
        case .dashboardCurrent:      return "/api/v2/dashboard/current/all/all"
        case .hostsMonitorSearch:    return "/api/v2/hosts/monitor/search"
        case .dashboardSystemRestart: return "/api/v2/dashboard/system/restart/:target"
        case .dashboardTopCPU:       return "/api/v2/dashboard/current/top/cpu"
        case .dashboardTopMem:       return "/api/v2/dashboard/current/top/mem"
        case .settingsSearch:        return "/api/v2/core/settings/search"
        // 面板 Web 端抓包路径（无 /core 前缀），v2 网关对两种前缀等价路由
        case .settingsSearchPanel:   return "/api/v2/settings/search"
        case .settingsUpdate:        return "/api/v2/settings/update"
        case .coreSettingsProxyUpdate: return "/api/v2/core/settings/proxy/update"
        case .settingsUpgradeCheck:  return "/api/v2/core/settings/upgrade"
        case .settingsUpgrade:       return "/api/v2/core/settings/upgrade"
        case .settingsUpgradeReleases: return "/api/v2/core/settings/upgrade/releases"
        case .deviceBase:            return "/api/v2/toolbox/device/base"
        case .deviceCheckDns:        return "/api/v2/toolbox/device/check/dns"
        case .deviceUpdateConf:      return "/api/v2/toolbox/device/update/conf"
        case .deviceUpdateHost:      return "/api/v2/toolbox/device/update/host"
        case .deviceUpdatePasswd:    return "/api/v2/toolbox/device/update/passwd"
        case .deviceZoneOptions:     return "/api/v2/toolbox/device/zone/options"
        case .toolboxScan:           return "/api/v2/toolbox/scan"
        case .toolboxClean:          return "/api/v2/toolbox/clean"
        case .containersSearch:      return "/api/v2/containers/search"
        case .containersListStats:      return "/api/v2/containers/list/stats"
        case .containersStats:          return "/api/v2/containers/stats/:containerID"
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
        case .containersImagePull:      return "/api/v2/containers/image/pull"
        case .containersImageRemove:    return "/api/v2/containers/image/remove"
        case .containersRepoSearch:     return "/api/v2/containers/repo/search"
        case .containersRepoCreate:     return "/api/v2/containers/repo"
        case .containersRepoUpdate:     return "/api/v2/containers/repo/update"
        case .containersRepoDelete:     return "/api/v2/containers/repo/del"
        case .containersRepoSync:       return "/api/v2/containers/repo/status"
        case .websitesSearch:        return "/api/v2/websites/search"
        case .websitesCreate:        return "/api/v2/websites"
        case .websitesCheck:         return "/api/v2/websites/check"
        case .websitesSSLSearch:     return "/api/v2/websites/ssl/list"
        case .websitesDelete:        return "/api/v2/websites/del"
        case .websitesUpdate:        return "/api/v2/websites/update"
        case .websitesOperate:       return "/api/v2/websites/operate"
        case .websitesDetail:        return "/api/v2/websites/:id"
        case .websitesConfig:        return "/api/v2/websites/config"
        case .websitesConfigUpdate:  return "/api/v2/websites/config/update"
        case .websitesRedirectList:  return "/api/v2/websites/redirect"
        case .websitesRedirectUpdate: return "/api/v2/websites/redirect/update"
        case .websitesRedirectFile:  return "/api/v2/websites/redirect/file"
        case .websitesAuths:         return "/api/v2/websites/auths"
        case .websitesAuthsUpdate:   return "/api/v2/websites/auths/update"
        case .websitesDomains:       return "/api/v2/websites/domains/:id"
        case .websitesNginxConfig:   return "/api/v2/websites/:id/config/openresty"
        case .websitesNginxUpdate:   return "/api/v2/websites/nginx/update"
        case .websitesLogRead:       return "/api/v2/files/read/website?operateNode=local"
        case .websitesHTTPSRead:     return "/api/v2/websites/:id/https"
        case .websitesHTTPSUpdate:   return "/api/v2/websites/:id/https"
        case .websitesProxiesList:   return "/api/v2/websites/proxies"
        case .websitesProxiesUpdate: return "/api/v2/websites/proxies/update"
        case .websitesProxiesFile:   return "/api/v2/websites/proxies/file"
        case .websitesProxiesStatus: return "/api/v2/websites/proxies/status"
        case .websitesSSLList:       return "/api/v2/websites/ssl/search"
        case .websitesSSLDetail:     return "/api/v2/websites/ssl/:id"
        case .websitesSSLUpload:     return "/api/v2/websites/ssl/upload"
        case .websitesSSLDelete:     return "/api/v2/websites/ssl/del"
        case .websitesSSLDownload:   return "/api/v2/websites/ssl/download"
        case .websitesSSLCreate:     return "/api/v2/websites/ssl"
        case .websitesSSLObtain:     return "/api/v2/websites/ssl/obtain"
        case .websitesSSLUpdate:     return "/api/v2/websites/ssl/update"
        case .websitesSSLLog:        return "/api/v2/files/read/ssl"
        case .websitesCaSearch:      return "/api/v2/websites/ca/search"
        case .websitesCaDetail:      return "/api/v2/websites/ca/:id"
        case .websitesCaCreate:      return "/api/v2/websites/ca"
        case .websitesCaDelete:      return "/api/v2/websites/ca/del"
        case .websitesCaObtain:      return "/api/v2/websites/ca/obtain"
        case .websitesAcmeSearch:    return "/api/v2/websites/acme/search"
        case .websitesAcmeCreate:    return "/api/v2/websites/acme"
        case .websitesAcmeDelete:    return "/api/v2/websites/acme/del"
        case .websitesDnsSearch:     return "/api/v2/websites/dns/search"
        case .websitesDnsCreate:     return "/api/v2/websites/dns"
        case .websitesDnsDelete:     return "/api/v2/websites/dns/del"
        case .websitesDnsUpdate:     return "/api/v2/websites/dns/update"
        case .openrestyConfig:       return "/api/v2/openresty"
        case .openrestyFile:         return "/api/v2/openresty/file"
        case .openrestyReset:        return "/api/v2/apps/installed/conf"
        case .openrestyStatus:       return "/api/v2/openresty/status"
        case .openrestyScope:        return "/api/v2/openresty/scope"
        case .openrestyUpdate:       return "/api/v2/openresty/update"
        case .openrestyHttps:        return "/api/v2/openresty/https"
        case .openrestyModules:      return "/api/v2/openresty/modules"
        case .openrestyModulesUpdate: return "/api/v2/openresty/modules/update"
        case .openrestyBuild:        return "/api/v2/openresty/build"
        case .commandsSearch:        return "/api/v2/core/commands/search"
        case .commandsCreate:        return "/api/v2/core/commands"
        case .commandsUpdate:        return "/api/v2/core/commands/update"
        case .commandsDelete:        return "/api/v2/core/commands/del"
        case .commandGroupsSearch:   return "/api/v2/core/groups/search"
        case .settingsSSHConn:       return "/api/v2/settings/ssh/conn"
        case .settingsSSHDefault:    return "/api/v2/settings/ssh/default"
        case .settingsSSHCheckInfo:  return "/api/v2/settings/ssh/check/info"
        case .settingsSSHSave:       return "/api/v2/settings/ssh"
        case .cronjobsSearch:        return "/api/v2/cronjobs/search"
        case .cronjobsCreate:        return "/api/v2/cronjobs"
        case .cronjobsUpdate:        return "/api/v2/cronjobs/update"
        case .cronjobsLoadInfo:      return "/api/v2/cronjobs/load/info"
        case .cronjobsHandle:        return "/api/v2/cronjobs/handle"
        case .cronjobsStatus:        return "/api/v2/cronjobs/status"
        case .cronjobsDelete:        return "/api/v2/cronjobs/del"
        case .cronjobsRecords:       return "/api/v2/cronjobs/search/records"
        case .cronjobsBackups:       return "/api/v2/backups/options"
        case .cronjobsUsers:         return "/api/v2/toolbox/device/users"
        case .cronjobsScripts:       return "/api/v2/cronjobs/script/options"
        case .scriptSearch:          return "/api/v2/core/script/search"
        case .scriptSync:            return "/api/v2/core/script/sync"
        case .coreSettingsUpdate:    return "/api/v2/core/settings/update"
        case .firewallBase:          return "/api/v2/hosts/firewall/base"
        case .firewallOperate:       return "/api/v2/hosts/firewall/operate"
        case .firewallSearch:        return "/api/v2/hosts/firewall/search"
        case .firewallPort:          return "/api/v2/hosts/firewall/port"
        case .firewallBatch:         return "/api/v2/hosts/firewall/batch"
        case .firewallUpdatePort:    return "/api/v2/hosts/firewall/update/port"
        case .firewallForward:       return "/api/v2/hosts/firewall/forward"
        case .firewallIP:            return "/api/v2/hosts/firewall/ip"
        case .firewallUpdateAddr:    return "/api/v2/hosts/firewall/update/addr"
        case .monitorNetOptions:     return "/api/v2/hosts/monitor/netoptions"
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
        case .databasesMongoSearch:       return "/api/v2/databases/mongodb/search"
        case .databasesMongoCreate:       return "/api/v2/databases/mongodb"
        case .databasesMongoRootPassword: return "/api/v2/databases/mongodb/root/password"
        case .databasesMongoPassword:     return "/api/v2/databases/mongodb/password"
        case .databasesMongoPrivilegesLoad: return "/api/v2/databases/mongodb/privileges"
        case .databasesMongoPrivileges:   return "/api/v2/databases/mongodb/privileges/change"
        case .databasesMongoDelCheck:     return "/api/v2/databases/mongodb/del/check"
        case .databasesMongoDel:          return "/api/v2/databases/mongodb/del"
        case .databasesUsersSearch:  return "/api/v2/databases/users/search"
        case .databasesGrantsSearch: return "/api/v2/databases/grants/search"
        case .databasesUsersCreate:  return "/api/v2/databases/users"
        case .databasesUsersDelete:  return "/api/v2/databases/users/del"
        case .databasesUsersUpdate:  return "/api/v2/databases/users/update"
        case .databasesUsersPassword: return "/api/v2/databases/users/password"
        case .databasesGrantsAdd:    return "/api/v2/databases/grants"
        case .databasesGrantsDelete: return "/api/v2/databases/grants/del"
        case .processStop:           return "/api/v2/process/stop"
        case .processListening:      return "/api/v2/process/listening"
        case .fail2banBase:          return "/api/v2/toolbox/fail2ban/base"
        case .fail2banUpdate:        return "/api/v2/toolbox/fail2ban/update"
        case .fail2banLoadConf:      return "/api/v2/toolbox/fail2ban/load/conf"
        case .fail2banUpdateByConf:  return "/api/v2/toolbox/fail2ban/update/byconf"
        case .fail2banOperate:       return "/api/v2/toolbox/fail2ban/operate"
        case .fail2banSearch:        return "/api/v2/toolbox/fail2ban/search"
        case .fail2banOperateSSHD:   return "/api/v2/toolbox/fail2ban/operate/sshd"
        case .ftpBase:               return "/api/v2/toolbox/ftp/base"
        case .ftpSearch:             return "/api/v2/toolbox/ftp/search"
        case .ftpCreate:             return "/api/v2/toolbox/ftp"
        case .ftpUpdate:             return "/api/v2/toolbox/ftp/update"
        case .ftpOperate:            return "/api/v2/toolbox/ftp/operate"
        case .ftpLogSearch:          return "/api/v2/toolbox/ftp/log/search"
        case .ftpDelete:             return "/api/v2/toolbox/ftp/del"
        case .ftpSync:               return "/api/v2/toolbox/ftp/sync"
        case .clamBase:              return "/api/v2/toolbox/clam/base"
        case .clamSearch:            return "/api/v2/toolbox/clam/search"
        case .clamCreate:            return "/api/v2/toolbox/clam"
        case .clamUpdate:            return "/api/v2/toolbox/clam/update"
        case .clamHandle:            return "/api/v2/toolbox/clam/handle"
        case .clamOperate:           return "/api/v2/toolbox/clam/operate"
        case .clamDelete:            return "/api/v2/toolbox/clam/del"
        case .clamRecordSearch:      return "/api/v2/toolbox/clam/record/search"
        case .clamFileSearch:        return "/api/v2/toolbox/clam/file/search"
        case .clamFileUpdate:        return "/api/v2/toolbox/clam/file/update"
        case .supervisorStatus:      return "/api/v2/hosts/tool/status"
        case .supervisorInit:        return "/api/v2/hosts/tool/init"
        case .supervisorServiceOperate: return "/api/v2/hosts/tool/operate"
        case .supervisorProcess:     return "/api/v2/hosts/tool/supervisor/process"
        case .supervisorProcessList: return "/api/v2/hosts/tool/supervisor/process"
        case .supervisorProcessFileGet: return "/api/v2/hosts/tool/supervisor/process/file/get"
        case .supervisorProcessFile: return "/api/v2/hosts/tool/supervisor/process/file"
        case .supervisorConfigGet:   return "/api/v2/hosts/tool/config/get"
        case .supervisorConfigSet:   return "/api/v2/hosts/tool/config/set"
        case .supervisorLogRead:     return "/api/v2/files/read/supervisor"
        case .filesSearch:           return "/api/v2/files/search"
        case .alertSearch:           return "/api/v2/alert/search"
        case .alertCreate:           return "/api/v2/alert"
        case .alertUpdate:           return "/api/v2/alert/update"
        case .alertDelete:           return "/api/v2/alert/del"
        case .alertLogsSearch:       return "/api/v2/alert/logs/search"
        case .alertDisksList:        return "/api/v2/alert/disks/list"
        case .alertConfigSearch:     return "/api/v2/alert/config/search"
        case .alertConfigInfo:       return "/api/v2/alert/config/info"
        case .alertConfigTest:       return "/api/v2/alert/config/test"
        case .alertConfigUpdate:     return "/api/v2/alert/config/update"
        case .alertConfigDelete:     return "/api/v2/alert/config/del"
        case .filesUpload:           return "/api/v2/files/upload"
        case .filesChunkUpload:      return "/api/v2/files/chunkupload"
        case .filesDownload:         return "/api/v2/files/download"
        case .wafStatus:             return "/api/v2/xpack/waf/status"
        case .wafWebsitesSearch:     return "/api/v2/xpack/waf/websites/search"
        case .wafWebsiteState:       return "/api/v2/xpack/waf/config/website/state"
        case .wafWebsiteRuleCC:      return "/api/v2/xpack/waf/website/rule/cc"
        case .wafConfigWebsite:      return "/api/v2/xpack/waf/config/website"
        case .wafConfigGlobal:       return "/api/v2/xpack/waf/config/global"
        case .wafConfigGlobalState:  return "/api/v2/xpack/waf/config/global/state"
        case .wafCdnUpdate:          return "/api/v2/xpack/waf/cdn/update"
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
        case .wafRuleCommonApply:    return "/api/v2/xpack/waf/rule/common/apply"
        case .wafRuleCc:             return "/api/v2/xpack/waf/rule/cc"
        case .wafLocationUpdate:     return "/api/v2/xpack/waf/location/update"
        case .wafSpider:             return "/api/v2/xpack/waf/config/global/spider"
        case .wafStat:               return "/api/v2/xpack/waf/stat"
        case .wafStatDays:           return "/api/v2/xpack/waf/stat/days"
        case .wafLogSearch:          return "/api/v2/xpack/waf/log/search"
        case .wafLogDetail:          return "/api/v2/xpack/waf/log/detail/:id"
        case .wafBlockSearch:        return "/api/v2/xpack/waf/block/search"
        case .monitorQps:            return "/api/v2/xpack/monitor/qps"
        case .monitorStat:           return "/api/v2/xpack/monitor/stat"
        case .monitorVisitors:       return "/api/v2/xpack/monitor/visitors"
        case .monitorVisitorsLoc:    return "/api/v2/xpack/monitor/visitors/loc"
        case .monitorRank:           return "/api/v2/xpack/monitor/rank"
        case .monitorLogsSearch:     return "/api/v2/xpack/monitor/logs/search"
        case .monitorLogsDetail:     return "/api/v2/xpack/monitor/logs/detail"
        case .wafLocationsWorld:     return "/api/v2/xpack/waf/locations/world"
        case .settingsBaseDir:       return "/api/v2/settings/basedir"
        case .filesUserGroup:        return "/api/v2/files/user/group"
        case .filesCreate:           return "/api/v2/files"
        case .filesDel:              return "/api/v2/files/del"
        case .filesRename:           return "/api/v2/files/rename"
        case .filesContent:          return "/api/v2/files/content"
        case .filesBatchCheck:       return "/api/v2/files/batch/check"
        case .filesRecycleStatus:    return "/api/v2/files/recycle/status"
        case .filesRecycleSearch:    return "/api/v2/files/recycle/search"
        case .filesRecycleReduce:    return "/api/v2/files/recycle/reduce"
        case .filesRecycleClear:     return "/api/v2/files/recycle/clear"
        case .sshOperate:            return "/api/v2/hosts/ssh/operate"
        case .sshSearch:             return "/api/v2/hosts/ssh/search"
        case .sshUpdate:             return "/api/v2/hosts/ssh/update"
        case .sshFile:               return "/api/v2/hosts/ssh/file"
        case .sshFileUpdate:         return "/api/v2/hosts/ssh/file/update"
        case .sshCertSearch:         return "/api/v2/hosts/ssh/cert/search"
        case .sshCertCreate:         return "/api/v2/hosts/ssh/cert"
        case .sshCertUpdate:         return "/api/v2/hosts/ssh/cert/update"
        case .sshCertDelete:         return "/api/v2/hosts/ssh/cert/delete"
        case .sshCertSync:           return "/api/v2/hosts/ssh/cert/sync"
        case .disksList:             return "/api/v2/hosts/disks"
        case .disksPartition:        return "/api/v2/hosts/disks/partition"
        case .disksMount:            return "/api/v2/hosts/disks/mount"
        case .disksUnmount:          return "/api/v2/hosts/disks/unmount"
        case .hostsSearch:           return "/api/v2/hosts/search"
        case .hostsCreate:           return "/api/v2/hosts"
        case .hostsUpdate:           return "/api/v2/hosts/update"
        case .hostsDelete:           return "/api/v2/hosts/del"
        case .hostsTestByInfo:       return "/api/v2/hosts/test/byinfo"
        case .hostsTestByID:         return "/api/v2/hosts/test/byid"
        case .hostGroupsSearch:      return "/api/v2/groups/search"
        case .websitesGroupsSearch:  return "/api/v2/groups/search"
        case .websitesGroupsCreate:  return "/api/v2/groups"
        case .websitesGroupsUpdate:  return "/api/v2/groups/update"
        case .websitesGroupsDelete:  return "/api/v2/groups/del"
        case .coreGroupsSearch:      return "/api/v2/core/groups/search"
        case .coreGroupsCreate:      return "/api/v2/core/groups"
        case .coreGroupsUpdate:      return "/api/v2/core/groups/update"
        case .coreGroupsDelete:      return "/api/v2/core/groups/del"
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
        case .appStoreSettingConfig: return "/api/v2/core/settings/apps/store/config"
        case .appStoreSettingUpdate: return "/api/v2/core/settings/apps/store/update"
        case .appsStoreSearch:       return "/api/v2/apps/search"
        case .appsStoreDetail:       return "/api/v2/apps/:key"
        case .appsTags:              return "/api/v2/apps/tags"
        case .appsSyncRemote:        return "/api/v2/apps/sync/remote"
        case .appsSyncLocal:         return "/api/v2/apps/sync/local"
        case .appsIcon:              return "/api/v2/apps/icon/:appID"
        case .appsServices:          return "/api/v2/apps/services/:type"
        case .logsTaskRead:          return "/api/v2/logs/tasks/read"
        case .logsTaskCount:         return "/api/v2/logs/tasks/executing/count"
        case .logsTaskSearch:        return "/api/v2/logs/tasks/search"
        case .backupsLocal:          return "/api/v2/backups/local?operateNode=local"
        case .backupsRecordSearch:   return "/api/v2/backups/record/search?operateNode=local"
        case .backupsRecordSize:     return "/api/v2/backups/record/size?operateNode=local"
        case .backupsBackup:         return "/api/v2/backups/backup?operateNode=local"
        case .backupsRecover:        return "/api/v2/backups/recover?operateNode=local"
        case .backupsRecordDelete:   return "/api/v2/backups/record/del"
        case .backupsRecordDownload: return "/api/v2/backups/record/download?operateNode=local"
        case .backupAccountsSearch:  return "/api/v2/backups/search"
        case .backupAccountsBuckets: return "/api/v2/backups/buckets"
        case .backupAccountsCheck:   return "/api/v2/backups/conn/check"
        case .backupAccountsCreate:  return "/api/v2/backups"
        case .backupAccountsUpdate:  return "/api/v2/backups/update"
        case .backupAccountsDelete:  return "/api/v2/backups/del"
        case .logsOperation:         return "/api/v2/core/logs/operation"
        case .logsLogin:             return "/api/v2/core/logs/login"
        case .logsSystemFiles:       return "/api/v2/logs/system/files"
        case .logsSSHLog:            return "/api/v2/hosts/ssh/log"
        case .logsWebsitesList:      return "/api/v2/websites/list"
        case .logsReadSystem:        return "/api/v2/files/read/system"
        case .logsReadWebsite:       return "/api/v2/files/read/website"
        case .nodesCurrent:          return "/api/v2/core/xpack/nodes/current"
        case .nodesList:             return "/api/v2/core/nodes/list"
        case .licensesSearch:        return "/api/v2/core/licenses/search"
        case .licensesUpload:        return "/api/v2/core/licenses/upload"
        case .licensesBind:          return "/api/v2/core/licenses/bind"
        case .licensesUnbind:        return "/api/v2/core/licenses/unbind"
        case .licensesDel:           return "/api/v2/core/licenses/del"
        case .licensesSync:          return "/api/v2/core/licenses/sync"
        case .nodesTestByInfo:       return "/api/v2/core/xpack/nodes/test/byinfo"
        case .nodesCreate:           return "/api/v2/core/xpack/nodes"
        case .licensesOptions:       return "/api/v2/core/licenses/options"
        case .nodesSearch:           return "/api/v2/core/xpack/nodes/search"
        case .nodesUpdate:           return "/api/v2/core/xpack/nodes/update"
        case .nodesUpdateBase:       return "/api/v2/core/xpack/nodes/update/base"
        case .nodesSync:             return "/api/v2/core/xpack/nodes/sync"
        case .nodesRestart:          return "/api/v2/core/xpack/nodes/restart"
        case .nodesDelete:           return "/api/v2/core/xpack/nodes/del"
        case .nodesUpgradeLogs:      return "/api/v2/core/xpack/nodes/search/upgrade/logs"
        case .nodeGroupsSearch:      return "/api/v2/core/groups/search"
        case .aiAccountsSearch:      return "/api/v2/ai/accounts/search"
        case .aiAccountsCreate:      return "/api/v2/ai/accounts"
        case .aiAccountsUpdate:      return "/api/v2/ai/accounts/update"
        case .aiAccountsDelete:      return "/api/v2/ai/accounts/delete"
        case .aiAccountProviders:    return "/api/v2/ai/accounts/providers"
        case .aiAccountModelsDiscover: return "/api/v2/ai/accounts/models/discover"
        case .aiAccountModelsList:   return "/api/v2/ai/accounts/models"
        case .aiAccountModelCreate:  return "/api/v2/ai/accounts/models/create"
        case .aiAccountModelUpdate:  return "/api/v2/ai/accounts/models/update"
        case .aiAccountModelDelete:  return "/api/v2/ai/accounts/models/delete"
        case .aiAgentsSearch:        return "/api/v2/ai/agents/search"
        case .aiAgentsCreate:        return "/api/v2/ai/agents"
        case .aiAgentsDeleteCheck:   return "/api/v2/ai/agents/delete/check"
        case .aiAgentsDelete:        return "/api/v2/ai/agents/delete"
        case .aiAgentWebsiteBind:    return "/api/v2/ai/agents/website/bind"
        case .aiAgentWebsiteUnbind:  return "/api/v2/ai/agents/website/unbind"
        case .aiAgentModelGet:       return "/api/v2/ai/agents/model/get"
        case .aiAgentModelUpdate:    return "/api/v2/ai/agents/model/update"
        case .aiAgentSkillsSearch:   return "/api/v2/ai/agents/skills/search"
        case .aiAgentSkillsInstall:  return "/api/v2/ai/agents/skills/install"
        case .aiAgentSkillsList:     return "/api/v2/ai/agents/skills/list"
        case .aiAgentOtherGet:       return "/api/v2/ai/agents/other/get"
        case .aiAgentOtherUpdate:    return "/api/v2/ai/agents/other/update"
        case .aiAgentConfigFileGet:  return "/api/v2/ai/agents/config-file/get"
        case .aiAgentChannelGet:     return "/api/v2/ai/agents/channel/:type/get"
        case .aiAgentChannelUpdate:  return "/api/v2/ai/agents/channel/:type/update"
        case .aiAgentWeixinLogin:    return "/api/v2/ai/agents/channel/weixin/login"
        case .aiAgentChannelDelete:  return "/api/v2/ai/agents/channel/delete"
        case .aiMcpSearch:           return "/api/v2/ai/mcp/search"
        case .aiMcpServerCreate:     return "/api/v2/ai/mcp/server"
        case .aiMcpServerUpdate:     return "/api/v2/ai/mcp/server/update"
        case .aiMcpServerDelete:     return "/api/v2/ai/mcp/server/del"
        case .aiMcpServerOperate:    return "/api/v2/ai/mcp/server/op"
        case .aiMcpStatusSync:       return "/api/v2/ai/mcp/server/status/sync"
        case .aiMcpConnectionTest:   return "/api/v2/ai/mcp/server/connection/test"
        case .aiMcpDomainGet:        return "/api/v2/ai/mcp/domain/get"
        case .aiMcpDomainBind:       return "/api/v2/ai/mcp/domain/bind"
        case .aiMcpDomainUpdate:     return "/api/v2/ai/mcp/domain/update"
        case .aiOllamaModelSearch:   return "/api/v2/ai/ollama/model/search"
        case .aiOllamaModelCreate:   return "/api/v2/ai/ollama/model"
        case .aiOllamaModelRecreate: return "/api/v2/ai/ollama/model/recreate"
        case .aiOllamaModelDelete:   return "/api/v2/ai/ollama/model/del"
        case .aiOllamaClose:         return "/api/v2/ai/ollama/close"
        case .aiDomainGet:           return "/api/v2/ai/domain/get"
        case .aiDomainBind:          return "/api/v2/ai/domain/bind"
        case .aiDomainUpdate:        return "/api/v2/ai/domain/update"
        }
    }

    var method: String {
        switch self {
        case .dashboardOS, .dashboardBase, .dashboardCurrent, .dashboardTopCPU, .dashboardTopMem,
             .monitorNetOptions,
             .appsIgnoredList, .appsStoreDetail,
             .appsTags,
             .disksList,
             .appsInstalledDeleteCheck, .appsInstalledParams,
             .appStoreSettingConfig,
             .websitesDetail, .websitesNginxConfig, .websitesHTTPSRead, .websitesDomains,
             .websitesSSLDetail, .cronjobsBackups, .cronjobsUsers, .cronjobsScripts,
             .containersListStats, .containersStats, .containersDockerStatus, .containersImageAll,
             .containersImageOptions, .containersNetwork, .containersVolume, .containersLimit,
             .appsIcon, .databasesRedisCheck,
             .appsServices,
             .logsTaskCount,
             .fail2banBase, .fail2banLoadConf,
             .ftpBase,
             .supervisorProcessList,
             .deviceZoneOptions,
             .alertDisksList,             .wafStatus, .wafConfigGlobal,
             .wafLocationsWorld, .wafLogDetail,
             .wafStat, .wafStatDays,
             .settingsBaseDir,
             .filesRecycleStatus,
             .settingsUpgradeCheck, .settingsUpgradeReleases,
             .openrestyConfig, .openrestyStatus, .openrestyHttps, .openrestyModules,
             .settingsSSHConn,
             .logsSystemFiles, .logsWebsitesList,
             .nodesCurrent, .licensesOptions,
             .backupsLocal,
             .filesDownload,
             .aiAccountProviders, .aiMcpDomainGet:
            return "GET"
        default:
            return "POST"
        }
    }
}
