# ATS 立场与提审备注模板（审计项 E2）

- 日期：2026-09-06
- 关联：`doc/references/project-audit-report-2026-09.md` §6-E2；`1PanelClient/Info.plist`
- 用途：上架前的纯写作准备。当前分发以侧载为主，本文档在未来提审时直接取用，无需再考古。

## 一、ATS 立场

**结论：ATS 保持全开（NSAppTransportSecurity 不做任何豁免），明文 HTTP 需求由用户配置承担，UI 有完整警示链。**

事实依据（2026-09 审计确认）：

1. `Info.plist` 中不含 `NSAllowsArbitraryLoads` 等任何 ATS 例外键——App 自身的所有
   网络请求默认仅允许 HTTPS。
2. 明文 HTTP 仅发生在一种场景：用户主动添加了 `http://` 前缀的 1Panel 面板地址。
   这是产品核心功能（自托管面板常部署在局域网/Tailscale 等私有网络，HTTPS 证书未必就绪），
   且地址由用户手动输入，App 不内置任何明文端点。
3. UI 警示链完整：
   - 设置内提供「仅允许 HTTPS 连接」开关（默认关闭、可全局禁止明文）；
   - 添加 `http://` 服务器时界面明示「连接未加密」风险；
   - 明文连接的面板在列表/详情持续展示非安全标识。
4. 侧载场景（当前主分发方式）ATS 同样生效，本立场与分发方式无关。

**立场**：不为迎合个别明文面板而全局降级 ATS；用户对自己输入的地址拥有决定权，
App 的义务是把风险讲清楚并提供全局收紧开关。此立场符合 App Store 审核指南
2.5.2 / ATS 例外条款中「用户配置的服务器地址」惯例（参考各类自托管客户端 App 的处理）。

## 二、提审备注（Review Notes）模板

未来在 App Store Connect「App 信息 → 审核备注」中粘贴，按需微调：

### 英文版

> This app is a client for 1Panel, a self-hosted server management panel
> (open source, https://1panel.cn). It does not include any built-in server;
> users must add their own panel address and API key.
>
> For review: a demo panel may not be publicly accessible — the app requires a
> user-configured server. All network requests go to user-entered addresses only;
> the app collects no analytics and contains no third-party SDKs
> (see PrivacyInfo.xcprivacy: data collection = none).
>
> If a plain-HTTP panel address is configured by the user, the app shows a clear
> unencrypted-connection warning, and a global "HTTPS only" switch is available
> in Settings. ATS is fully enabled with no exceptions in Info.plist.

### 中文版（中国区提审备用）

> 本应用为开源服务器管理面板 1Panel（https://1panel.cn）的 iOS 客户端。
> 应用内不含任何内置服务器，需用户自行填入自己的面板地址与 API 密钥后使用。
> 应用不收集任何分析数据、不含第三方 SDK（隐私清单声明为「不收集」）。
> 用户若配置 http:// 明文面板地址，界面会明示「连接未加密」风险，且设置内提供
> 「仅允许 HTTPS 连接」全局开关；Info.plist 未配置任何 ATS 豁免。

## 三、遗留（上架前再处理）

- 演示面板：提审需要一台审核员可访问的 HTTPS 演示面板（只读账号），届时准备。
- 隐私政策正式 URL：现为仓库文档地址（见 E5），上架前替换。
