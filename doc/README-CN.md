# 1PanelClient

iOS 客户端 for [1Panel](https://1panel.cn) — 开源 Linux 服务器运维管理面板。

原生 Swift + SwiftUI 构建，通过 1Panel v2 OpenAPI 实现服务器远程管理。

> English documentation: [README-EN.md](README-EN.md)
>
> 完整功能清单与说明：[FEATURES.md](FEATURES.md)

## 功能

### 首页
- 实时资源卡片（负载 / CPU / 内存 / 各磁盘挂载点，3 秒轮询）与监控图表入口
- 网站 / 应用（含可升级数）/ 数据库 / 容器统计卡，点击直达对应模块
- 面板信息与系统信息（版本、IP、时区、发行版、内核、运行时间）、版本升级横幅与更新日志、证书到期倒计时
- 多机总览卡片

### 管理

**应用**
- **应用程序** — 已安装应用管理（启停 / 重启 / 日志 / 卸载 / 参数重建）、应用商店安装、升级（Compose 行级差异采纳）
- **AI** — 模型账号与模型池（多供应商 / 可用性验证）、智能体（消息频道、技能市场、插件市场、多角色、会话对话）、MCP Server、Ollama 本地模型、vLLM 推理实例、模型下载器（HuggingFace / ModelScope）
- **网站** — 创建向导（一键部署 / 反向代理 / 静态网站）、分组与批量操作、OpenResty 管理与 Nginx 配置编辑；详情含 HTTPS 配置、日志及完整设置（域名、默认文档、流量限制、反向代理、负载均衡、密码访问、跨域访问、真实 IP、伪静态、防盗链、重定向、PHP 运行环境、关联资源、基础信息）；网站监控（QPS / 访客趋势 / 请求日志）
- **证书** — 证书列表与详情（申请 / 上传 / 重新申请 / 下载 / 删除 / 申请日志）、Acme 账户、DNS 账户、自签证书 CA（创建 / 签发证书）
- **数据库** — MySQL / MariaDB / PostgreSQL / MongoDB / Redis 实例管理，数据库与用户增删改、连接信息、改密码 / 改权限、状态与性能调整、数据库终端
- **容器** — 容器列表 / 创建向导 / 编辑 / 升级 / 详情 / 终端 / 实时监控；镜像（拉取 / 更新 / 打标签 / 清理 / 仓库）、编排模板、网络、存储卷、Docker daemon 配置

**主机**
- **SSH** — 本机与远程主机终端（SwiftTerm）、主机管理、SSH 密钥、在线会话管理、快速命令、面板保留会话
- **文件** — 目录浏览、上传 / 下载（传输队列）、远程下载 wget（实时进度）、压缩 / 解压、权限修改、回收站、收藏夹、文本编辑
- **监控** — 负载 / CPU / 内存 / 磁盘 I/O / 网络历史曲线（1h–7d）、监控设置
- **进程** — 实时进程与网络连接、搜索排序、结束进程
- **防火墙** — 端口 / IP 规则、端口转发、面板端口白名单、Docker 端口守护、规则导入导出

**工具箱**
- Fail2ban（黑白名单 / 配置编辑）、FTP（账号管理）、病毒扫描（ClamAV 规则 / 报告）、进程守护（Supervisor）、磁盘管理（分区 / 挂载）、缓存清理

**高级功能**
- GPU 监控、WAF（状态 / 监控 / 黑白名单与 IP 组 / 网站 / 全局配置）、网站监控、多机管理（1Panel 专业版，App 全局跟随当前节点）

**面板**
- 面板设置（基础设置、设备 DNS / Hosts、许可证管理）、告警通知（规则 / 日志 / 邮箱 · Bark · Webhook 发送方式）、备份账号（MINIO / OSS / WebDAV / SFTP 等 11 种）、计划任务（Shell / 备份 / 快照 / URL / 日志清理等类型、执行记录、导入导出、脚本库）、快照（创建 / 恢复 / 导入）、任务中心、日志（面板 / 操作 / SSH 登录 / 系统）

### 交互与体验
- 列表操作全站统一：单击进入 + 长按操作菜单（启停 / 编辑 / 删除等）
- 表单描边样式组件体系、中英双语即时切换、iPad 自适应布局（侧栏 / 图标栏 / 底部 Tab 三形态）

### 设置
- 多服务器管理（Keychain 安全存储）、服务器连接测试、分组管理
- 仅允许 HTTPS 连接开关（默认关闭；开启后拒绝所有 http:// 明文面板地址，HTTP 地址保存时也会给出明文风险提示）
- 应用锁（FaceID / TouchID 生物识别 + 4 位数字密码回退）
- 外观（跟随系统 / 亮色 / 暗色）与界面语言（中英双语，即时切换）

### 桌面小组件
- 服务器状态概览小组件、容器快捷操作小组件（App Intents 交互式按钮）

各模块的详细说明见 [FEATURES.md](FEATURES.md)。

## 截图

<!-- TODO: 添加截图 -->

## 环境要求

- iOS 26.0+（与工程部署目标一致）
- Xcode 26+
- 1Panel v2（面板端需开启 OpenAPI 并创建 API Key；不支持 v1）

## 安装

### 方式一：LiveContainer（免越狱，推荐）

1. 从 [Releases](https://github.com/xy2026yi/1PanelClient/releases) 下载最新的 `1PanelClient.ipa`
2. 将 IPA 传到 iPhone
3. 使用 [LiveContainer](https://github.com/khanhduytran0/LiveContainer) 导入运行

### 方式二：侧载签名

如果你有 Apple 开发者账号或自签工具（AltStore / Sideloadly / TrollStore），可直接签名安装 IPA。

### 方式三：自行编译

```bash
git clone https://github.com/xy2026yi/1PanelClient.git
cd 1PanelClient
```

用 Xcode 打开 `1PanelClient.xcodeproj`，修改 Bundle ID 和 Team，连接真机 Build & Run。

## 从源码打包 IPA

仓库内置了未签名 IPA 打包脚本（无需证书）：

```bash
cd 1PanelClient
./build-ipa.sh                    # 输出到 ~/Desktop/1PanelClient.ipa
./build-ipa.sh ~/path/to/output.ipa  # 自定义输出路径
```

生成的 IPA 为未签名版本，适用于 LiveContainer 或侧载工具。

## 运行测试

```bash
cd 1PanelClient
xcodebuild test -project 1PanelClient.xcodeproj -scheme 1PanelClient \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

或在 Xcode 中直接 Cmd+U。测试（Swift Testing）覆盖：Token 签名算法（MD5 固定向量）、API 业务信封解析、Keychain 增删改查、连接安全策略（http 明文识别 / 仅 HTTPS 拦截）、应用升级 Compose 差异、监控图表窗口、节点与多机模型、网站监控与 WAF 监控模型、App Intents、本地化文案。

## 项目结构

```
1PanelClient/
├── 1PanelClient/                # 主 App target
│   ├── _PanelClientApp.swift    # App 入口
│   ├── ContentView.swift
│   ├── Assets.xcassets
│   └── Features/                # 各功能模块（Main/Overview/Manage/Apps/
│   │                            #   Websites/Certificates/Databases/Containers/
│   │                            #   Cronjobs/Terminal/Firewall/Process/Toolbox/
│   │                            #   Backups/Logs/Server/Settings …）
├── PanelShared/                 # 主 App 与小组件共享代码
│   ├── Core/                    # APIClient / APIEndpoints / KeychainStore /
│   │                            #   ServerManager / SecurityGate
│   ├── Models/                  # 数据模型（API 响应、实体定义）
│   ├── Intents/                 # App Intents（快捷指令 / 小组件交互）
│   └── Shared/                  # 公共组件、设计 Token、国际化
├── PanelWidgets/                # 桌面小组件扩展（服务器状态 / 容器快捷操作）
├── 1PanelClientTests/           # 单元测试（Swift Testing）
├── scripts/                     # i18n 辅助脚本（文案迁移 / 同步）
└── build-ipa.sh                 # 未签名 IPA 打包脚本
```

## 技术栈

| 项目 | 说明 |
|------|------|
| 语言 | Swift 5 |
| UI 框架 | SwiftUI（NavigationStack push 导航） |
| 最低版本 | iOS 26.0 |
| 网络 | URLSession + Combine |
| 终端 | 原生 URLSessionWebSocketTask |
| 安全存储 | Keychain Services（App Group 共享给小组件） |
| 加密 | CryptoKit（MD5 Token 生成） |
| 小组件 | WidgetKit + App Intents |
| 测试 | Swift Testing |

## 1Panel API 认证

App 使用 1Panel v2 OpenAPI 的 Token 认证机制：

```
Timestamp = Unix 时间戳（秒）
Token     = MD5("1panel" + APIKey + Timestamp)

请求头:
  1Panel-Token:     <Token>
  1Panel-Timestamp: <Timestamp>
```

API Key 在 1Panel 面板端「面板设置 → 接口」中创建，存储在 iPhone 的 Keychain 中。

## License

本项目基于 [GPL-3.0](../LICENSE) 许可发布。
