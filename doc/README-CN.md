# 1PanelClient

iOS 客户端 for [1Panel](https://1panel.cn) — 开源 Linux 服务器运维管理面板。

原生 Swift + SwiftUI 构建，通过 1Panel v2 OpenAPI 实现服务器远程管理。

> English documentation: [README-EN.md](README-EN.md)
>
> 完整功能清单与说明：[FEATURES.md](FEATURES.md)

## 功能

### 首页
- 资源概览卡片（CPU、内存、磁盘、网络、负载）与实时监控图表
- 系统信息（主机名、系统版本、内核、运行时间）
- 面板版本更新检测、证书到期倒计时
- 多机总览卡片、应用/容器状态卡片

### 管理
- **应用程序** — 已安装应用管理、应用商店安装/卸载、升级（Compose 差异对比）、应用日志
- **网站** — 网站列表与配置、反向代理、SSL 证书管理（申请/手动/自签/DNS/HTTP）、网站日志、网站监控
- **数据库** — MySQL / PostgreSQL / Redis 实例管理、数据库终端、连接信息
- **容器** — Docker 容器列表/创建/编辑/详情/终端、镜像管理（拉取/清理/仓库）、容器实时监控
- **计划任务** — 定时任务 CRUD、立即执行、执行记录、日志查看、脚本库
- **终端** — WebSocket 远程终端（主机 / 容器 / 数据库 / SSH 主机）
- **文件** — 服务器文件管理
- **监控** — 负载 / CPU / 内存 / 磁盘 I/O / 网络监控图表
- **进程** — 系统进程监控
- **防火墙 / Fail2ban / WAF** — 端口与 IP 规则、SSH 防暴力破解、Web 应用防火墙（规则 / 黑白名单 / 监控）
- **告警通知** — 告警规则、告警日志、发送方式配置
- **备份账号** — MINIO / WebDAV / SFTP 备份存储与备份列表
- **任务中心** — 应用同步、镜像拉取等异步任务与日志
- **日志** — 面板 / 操作 / SSH 登录 / 网站日志查看
- **面板/服务器管理** — 重启面板与服务器
- **多机管理** — 节点概览 / 详情 / 添加 / 切换（1Panel 专业版），App 全局跟随当前节点

### 设置
- 多服务器管理（Keychain 安全存储）、服务器连接测试
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

MIT
