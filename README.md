# 1PanelClient

iOS client for [1Panel](https://1panel.cn) — the open-source Linux server management panel.
（[1Panel](https://1panel.cn) 的 iOS 客户端 — 开源 Linux 服务器运维管理面板。）

原生 Swift + SwiftUI 构建，通过 1Panel v2 OpenAPI 远程管理服务器：多服务器 / 多节点管理、应用商店、网站与 SSL 证书、数据库、Docker 容器与终端、计划任务、防火墙 / WAF、监控告警等 19 个管理模块，并附带桌面小组件与应用锁。

## 文档 / Documentation

- 中文文档：[doc/README-CN.md](doc/README-CN.md)
- English docs: [doc/README-EN.md](doc/README-EN.md)
- 功能列表：[doc/FEATURES.md](doc/FEATURES.md)

## 快速开始

```bash
git clone https://github.com/xy2026yi/1PanelClient.git
cd 1PanelClient
```

用 Xcode 26+ 打开 `1PanelClient/1PanelClient.xcodeproj`，连接真机 Build & Run；或使用 `build-ipa.sh` 打包未签名 IPA。详见上方文档。

## License

MIT
