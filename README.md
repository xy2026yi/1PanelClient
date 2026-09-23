# 1PanelClient

iOS client for [1Panel](https://1panel.cn) — the open-source Linux server management panel.
（[1Panel](https://1panel.cn) 的 iOS 客户端 — 开源 Linux 服务器运维管理面板。）

原生 Swift + SwiftUI 构建，通过 1Panel v2 OpenAPI 远程管理服务器：多服务器 / 多节点管理、应用商店、网站与 SSL 证书、数据库、Docker 容器与终端、计划任务、防火墙 / WAF、监控告警等 19 个管理模块，并附带桌面小组件与应用锁。

## 面板版本适配 / Panel Version Compatibility

当前适配的 1Panel 面板版本为 **v2.3.0 – v2.3.1**（防火墙模块基于 v2.3.0 重构后 API，旧版面板进入防火墙页会提示升级）。原则上支持 **v2.3.x** 系列：上游后续 v2.3.x 小版本若无模块级大改动即直接兼容；遇到显示 / 功能问题时，请先确认服务端面板版本在 v2.3.x 范围内。

接口请求与页面显示均基于该版本抓包对齐；面板版本过高或过低时，接口字段口径可能不一致，导致数据显示异常或部分功能不可用。遇到显示 / 功能问题时，请先确认服务端面板版本是否为适配版本。

This client is currently aligned with 1Panel **v2.3.0 – v2.3.1** (the firewall module targets the v2.3.0 rebuilt API; older panels are prompted to upgrade). The whole **v2.3.x** series is supported in principle — later v2.3.x patch releases are expected to work as long as upstream makes no module-level breaking changes. If something looks wrong, first check that your panel version is within v2.3.x.

## 文档 / Documentation

- 中文文档：[doc/README-CN.md](doc/README-CN.md)
- English docs: [doc/README-EN.md](doc/README-EN.md)
- 功能列表：[doc/FEATURES.md](doc/FEATURES.md)
- 功能测试清单：[doc/TEST-CHECKLIST.md](doc/TEST-CHECKLIST.md)

## 测试状态 / Testing Status

> **假设声明（2026-09）：本项目当前仅完成了开发，全部功能尚未经过任何真机 / 模拟器的测试验证。**
> 单元测试（323 项）已全绿并接入 GitHub Actions CI，但 UI 与真实面板交互尚待人工验收——请按 [功能测试清单](doc/TEST-CHECKLIST.md) 逐项测试标记；清单中也列出了建议的测试环境与重点模块。

## 快速开始

```bash
git clone https://github.com/xy2026yi/1PanelClient.git
cd 1PanelClient
```

用 Xcode 26+ 打开 `1PanelClient/1PanelClient.xcodeproj`，连接真机 Build & Run；或使用 `build-ipa.sh` 打包未签名 IPA。详见上方文档。

## License

本项目基于 [GPL-3.0](LICENSE) 许可发布。
1Panel 本体（[1Panel-dev/1Panel](https://github.com/1Panel-dev/1Panel)）同样采用 GPL-3.0。
