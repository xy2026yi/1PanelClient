# 1PanelClient

iOS 客户端 for [1Panel](https://1panel.cn) — 开源 Linux 服务器运维管理面板。

原生 Swift + SwiftUI 构建，通过 1Panel v2 OpenAPI 实现服务器远程管理。

## 功能

### 首页
- 资源概览卡片（CPU、内存、磁盘、网络、负载）
- 系统信息（主机名、系统版本、内核、运行时间）
- 面板版本更新检测

### 管理
- **应用程序** — 已安装应用管理、应用商店安装/卸载、应用日志
- **网站** — 网站列表、反向代理、SSL 证书管理（申请/手动/自签/DNS/HTTP）
- **数据库** — MySQL / PostgreSQL / Redis 实例管理、数据库终端、连接信息
- **容器** — Docker 容器列表、容器详情、容器终端、镜像管理（拉取/清理/仓库）
- **计划任务** — 定时任务 CRUD、立即执行、执行记录、日志查看、脚本库
- **终端** — WebSocket 远程终端（主机 / 容器 / 数据库）
- **防火墙** — 端口规则、IP 规则管理
- **工具箱** — Fail2ban、WAF（黑白名单 IP/URL/UA 规则）、文件管理、SSH 配置、进程监控

### 设置
- 多服务器管理（Keychain 安全存储）
- 服务器连接测试
- 仅允许 HTTPS 连接开关（默认关闭；开启后拒绝所有 http:// 明文面板地址，HTTP 地址保存时也会给出明文风险提示）

## 截图

<!-- TODO: 添加截图 -->

## 环境要求

- iOS 26.0+（与工程部署目标一致）
- Xcode 26+
- 1Panel v2（面板端需开启 OpenAPI 并创建 API Key；不支持 v1）

## 安装

### 方式一：LiveContainer（免越狱，推荐）

1. 从 [Releases](../../releases) 下载最新的 `1PanelClient.ipa`
2. 将 IPA 传到 iPhone
3. 使用 [LiveContainer](https://github.com/khanhduytran0/LiveContainer) 导入运行

### 方式二：侧载签名

如果你有 Apple 开发者账号或自签工具（AltStore / Sideloadly / TrollStore），可直接签名安装 IPA。

### 方式三：自行编译

```bash
git clone https://github.com/你的用户名/1PanelClient.git
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

或在 Xcode 中直接 Cmd+U。首批测试覆盖：Token 签名算法（MD5 固定向量）、Keychain 增删改查、API 业务信封解析、连接安全策略（http 明文识别 / 仅 HTTPS 拦截）。

## 项目结构

```
1PanelClient/
├── 1PanelClient/
│   ├── _PanelClientApp.swift      # App 入口
│   ├── ContentView.swift
│   ├── Info.plist
│   ├── Core/
│   │   ├── Network/                # APIClient / APIEndpoints / APIError
│   │   └── Storage/                # KeychainStore / ServerManager
│   ├── Models/                     # 数据模型（API 响应、实体定义）
│   ├── Features/
│   │   ├── Main/                   # 底部 Tab 框架
│   │   ├── Overview/               # 首页概览
│   │   ├── Manage/                 # 管理列表入口
│   │   ├── Apps/                   # 应用管理
│   │   ├── AppStore/               # 应用商店
│   │   ├── Websites/               # 网站 / 反向代理
│   │   ├── Certificates/           # SSL 证书
│   │   ├── Databases/              # 数据库
│   │   ├── Containers/             # Docker 容器
│   │   ├── Cronjobs/               # 计划任务
│   │   ├── Terminal/               # WebSocket 终端
│   │   ├── Firewall/               # 防火墙
│   │   ├── Process/                # 进程监控
│   │   ├── Toolbox/                # Fail2ban / WAF / 文件 / SSH
│   │   └── Settings/               # 设置
│   └── Shared/                     # 公共组件、国际化
├── 1PanelClient.xcodeproj/
├── 1PanelClientTests/              # 单元测试（Swift Testing）
└── build-ipa.sh                    # IPA 打包脚本
```

## 技术栈

| 项目 | 说明 |
|------|------|
| 语言 | Swift 5 |
| UI 框架 | SwiftUI（NavigationStack push 导航） |
| 最低版本 | iOS 26.0 |
| 网络 | URLSession + Combine |
| 终端 | 原生 URLSessionWebSocketTask |
| 安全存储 | Keychain Services |
| 加密 | CryptoKit（MD5 Token 生成） |

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
