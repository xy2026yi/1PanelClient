# 1PanelClient 全面项目评估报告（v0.1.14）

> 对应计划书：`archive/docs/project-audit-plan-2026-09.md` ｜评估日期：2026-09-06
> 评估方式：静态代码审查 + 可自动化动态验证（全量测试 / Swift 6 探测构建 / SF Symbol 校验 / 归档包体测量）。需真机、Instruments、抓包的项目已标注待执行，未做臆测。

---

## 0. 结论速览（TL;DR）

| 级别 | 数量 | 内容 |
|---|---|---|
| 🔴 P0 确认 | 3 | C1 本地网络权限缺失（静态实锤）、E1 隐私清单缺失（实锤）、E8 归档密钥入库（实锤，处置待决） |
| 🔴 新发现缺陷 | 1 | 无效 SF Symbol `certificate`（3 处使用点，自签证书/CA 页图标空白） |
| 🟡 P1 发现 | 6 | D1 后台轮询不停（实锤）、D3 同接口重复请求场景（静态确认）、D4 大响应解码在主线程、E7 版本双写、B8 AppIntents 20 条中文未译 + 硬编码、E4 出口合规键缺失 |
| 🟢 验证通过 | — | 全量测试 107 用例通过；零警告（默认与 Swift 6 模式均验证）；API Key 零明文落盘零日志；git 无 .env/.key/.pem；Swift 6 迁移仅 11 错（半天量级） |
| ⛔ 待真机/Instruments | 10 项 | A1–A3/A5 基线、C1 真机复现、C5 大数据量、B4 走查矩阵、B5 Inspector、D2 内存、F2 回归 |

**对计划书的总体判断：** 计划方向正确、P0 判断准确（C1/E1 均被本次评估证实）；但 6 处现状描述已过时（见 §8），其中 B3/C4 的剩余工作量比计划预估明显小，D5 可直接完成。

---

## 1. §0 基线事实核对（计划书快照 vs 实测）

| 维度 | 计划书 | 实测 | 判定 |
|---|---|---|---|
| 代码规模 | 163 文件 / 约 55,000 行 | 163 文件 / 54,989 行 | ✅ |
| 测试 | 17 套件 107 用例 | 17 文件 107 个 `@Test`，**全部通过**（TEST SUCCEEDED，24.6s，iPhone 17 Pro 模拟器，Xcode 26.6） | ✅ |
| 依赖 | swiftterm 1.18.0 | SwiftTerm target + SwiftTerm_SwiftTerm.bundle（32KB 资源） | ✅ |
| 本地化 | 1954 词条；硬编码中文仅 4 处 | 1954 词条 ✅；硬编码中文实测 **6 处、全部在 `Features/Debug/DebugChartDemoView.swift`**（DEBUG 入口 `-chartDemo` 直达，Release 不可达，见 `_PanelClientApp.swift:47-59`）。真正用户可见的是 xcstrings 内 **20 条含中文词条缺 en 翻译**（详见 §3-B8） | ⚠️ 修正 |
| 部署目标 | iOS 26.5 | `IPHONEOS_DEPLOYMENT_TARGET = 26.5`（6 配置） | ✅ |
| 缓存架构 | ClientCache LRU 32 + PageVMStore LRU 32 | `APIClientCache.swift:49` capacity 默认 32；`Features/Main/PageVMStore.swift:24` capacity 32 | ✅ |
| 轮询 | 每 5 秒 dashboardCurrent | 两处循环：`ServersView.swift:65-72`（全服务器）、`OverviewTab.swift:136-143`（当前服务器）；均不感知 scenePhase | ✅（D1 实锤，见 §5） |
| 构建 | 零警告 | 默认模式增量构建 0 warning；**Swift 6 模式全新构建 0 warning**（11 error 另计，见 §5-D5） | ✅ |
| Info.plist | ATS 全开 + 文件共享 + FaceID；**无本地网络 key** | 全部属实；`NSLocalNetworkUsageDescription` 全仓库（plist/pbxproj/源码）零命中 | ✅（C1 实锤） |
| 隐私清单 | 三处均无 | 全仓库无任何 `.xcprivacy`；swiftterm 包内亦无 | ✅（E1 实锤） |
| 权限 API | 14 文件 required-reason | 实测 **12 文件**使用 `@AppStorage`/`UserDefaults`（不含测试） | ⚠️ 修正 |
| 日志 | os.Logger 2 处 | `APIClient.swift:169`（DEBUG-only）、`ServerManager.swift:125` | ✅ |
| scenePhase | 仅用于应用锁 | 应用锁（`ContentView.swift:31`）之外，`MonitorView.swift:237`、`ContainerMonitorView.swift:125` 页面级监控已有局部暂停先例——**但全局 5 秒轮询确实不停** | ⚠️ 细化 |

---

## 2. 动态验证记录（本次新增证据）

### 2.1 全量测试 ✅
```
xcodebuild test -project 1PanelClient.xcodeproj -scheme 1PanelClient \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
** TEST SUCCEEDED **（107 用例，测试阶段 24.6s）
```

### 2.2 Swift 6 语言模式探测（D5）✅ 已完成评估
`SWIFT_VERSION=6.0` 全新 DerivedData 构建：**11 error / 0 warning**，且 11 个错误全部是同一模式（非 Sendable 的 static 属性）：

| 文件 | 行 | 内容 |
|---|---|---|
| `PanelWidgets/QuickOpsWidget.swift` | 16,17 | static title/description |
| `PanelShared/Shared/Localization/L10n.swift` | 14 | static shared 单例 |
| `PanelShared/Intents/PanelIntents.swift` | 18,20,43,45 | typeDisplayRepresentation / caseDisplayRepresentations |
| `PanelShared/Intents/PanelEntities.swift` | 24,68,120,168 | defaultQuery（AppIntents 协议要求） |

**结论：迁移成本 ≤0.5 天**（与计划估时一致）。建议本次直接开启并清零，不必只留评估报告。AppIntents 的协议 static 可标 `@MainActor`，L10n 单例可 `nonisolated(unsafe)` + 文档化纪律。

### 2.3 SF Symbol 全量校验（B1 数据）
提取全部 `systemName:` 字面量：**186 处使用 / 50 个唯一名**，逐一在 macOS 26（NSImage，与 iOS 26.5 的 SF Symbols 7 同源）验证：

- ✅ 49 个有效
- 🔴 **1 个无效：`certificate`** —— `CertificatesTab.swift:178`（自签证书入口）、`CAView.swift:34`、`CAView.swift:133`。运行时渲染为空白，与 dc618c5 修过的 `chevron.up.forward` 同类。建议替换为 `checkmark.seal`（已验证存在）或自定义 `icon-cert`（`customIcon` 参数已备）。
- ⚠️ 动态拼接名（三元表达式/变量）约 31 处（如 `showCurrent ? "eye.slash" : "eye"`），逐个目测均为常见符号，计划书 B1 的"人工过目"项维持，但风险低。

### 2.4 包体近似基线（A4，非 App Store thinning 口径）
利用仓库内现成 `1PanelClient/build/1PanelClient.xcarchive`（Release、arm64 单架构已瘦身）：

| 项 | 尺寸 |
|---|---|
| 1PanelClient.app（未压缩） | **17 MB** |
| 主二进制（含 swiftterm 静态编入） | 12 MB |
| Assets.car | 3.4 MB |
| PlugIns/PanelWidgets.appex | 672 KB |
| en.lproj / zh-Hans.lproj | 104 KB / 52 KB |
| SwiftTerm_SwiftTerm.bundle | 32 KB |

swiftterm 源码编入主二进制无法单独拆分（这正是"体积占比"要回答的部分）；正式口径仍需 App Thinning 报告，此表作为初基线。

---

## 3. Phase B：UI 一致性审查发现

| ID | 结论 | 证据与剩余工作 |
|---|---|---|
| B1 | 🔴 发现 1 个无效 symbol | 见 §2.3。`SFSymbolAuditTests.swift` 建议尽快落库（把 NSImage 代理法换成真机语义的 `UIImage(systemName:) != nil` 断言） |
| B2 | 🟡 漂移集中在字体 | `.padding(数字)` 仅 **4 处**（极干净）；`.font(.system` **118 处**（最大漂移面，AppLock/MonitorView 等固定字号对 Dynamic Type 不友好）；`Color(red:)`/`.foregroundColor(.init` 7 处；`frame(width:` 67 处。建议规范：语义字体优先、字号收敛为常量 |
| B3 | 🟢 **计划前提过时，工作量下调** | 项目已有完整三态组件族：`LoadingStateView`（加载）、`LoadErrorStateView`（全页错误+重试，`CommonComponents.swift:366`，30 处调用）、`ErrorBanner`（错误横幅+重试，`CommonComponents.swift:335`）、`ContentUnavailableView` 系统空态 103 处。剩余工作从"定义组件并全量替换"降级为"一致性核对"：70 处「暂无」文案形态、76 处 `vm.errorMessage` 分支的呈现统一 |
| B4 | ⛔ 待真机矩阵 | 静态风险低：全工程 **零** `.white/.black` 固定前景色 |
| B5 | 🟡 部分 | `accessibilityLabel` 61 处（图标按钮如 ServersView 的 + 已带标签）；对比度/44pt/Reduce Motion 需 Inspector |
| B6 | 🟡 语义偏科 | Haptic 60 处：warning 47 / selection 8 / success 2 / error 2。破坏性操作覆盖充分；「成功提示统一」确认为弱项（仅 2 处 success） |
| B7 | 🟡 基本达标 | `.refreshable` 覆盖 **48 个文件**，14 个快照页全部在列；服务器移除有确认 alert（`ServersView.swift:107`）。Toast/Alert 边界、表单校验时机需人工清单 |
| B8 | 🟡 真实缺失比计划描述严重（但位置不同） | ① xcstrings 缺 en 含中文词条 **20 条**，集中在 AppIntents（快捷指令枚举/对话）与 Widget 描述：如「启动 / 停止 / 重启 / 关闭指定容器」「在线检查与 CPU / 内存 / 负载概览」「服务器概览」——en 模式下快捷指令与 Widget 商店会显示中文；② `PanelIntents.swift:18,43` `typeDisplayRepresentation` 为**硬编码中文字面量**（不经 L10n.t，en 模式无法本地化）；③ 另 96 条缺 en 词条为纯符号/格式串（"—"、"·"、"%lld%%" 等），不翻不影响。硬编码中文 6 处全在 DebugChartDemoView（Release 不可达，P2 清理） |

---

## 4. Phase C：首次访问审查发现

| ID | 结论 | 证据与剩余工作 |
|---|---|---|
| C1 | 🔴 **P0 静态实锤** | 全仓库无 `NSLocalNetworkUsageDescription`；而添加服务器的占位示例就是局域网 IP（`ServerEditView.swift:49` `http://10.0.0.1:36130`）。iOS 14+ 真机连本地地址需该 key 弹授权，缺失 → 首连静默失败，仅表现为超时。现有错误文案（`APIError.swift:34`）只提示模拟器的 macOS 设置，**未提示 iOS「设置→隐私与安全性→本地网络」**。修复：补 key（双语）+ 错误指引补 iOS 分支。真机复现仍按计划执行（R1） |
| C2 | ⛔ 待 A1 基线 | 静态看启动路径干净：App init 仅读主题 @AppStorage（`_PanelClientApp.swift:11`），无发现同步大 IO；ServerManager 首次访问时 Keychain 读 + 解码（`ServerManager.swift:118`）。需 Instruments 数字 |
| C3 | 🟡 两处弱项 | 已达标：占位示例、API Key 获取指引（提示 Section）、明文 HTTP 三重警示（inline Label + 保存 alert + httpsOnly 拦截，`ServerEditView.swift:55-59,103-108,119-129`）、测试连接不依赖业务模型（`ConnectionTester.swift`）。弱项：① 端口错（超时）与网络不可达共用同一文案，无法区分；② 无服务器时 ServersView 仅 footer 文案引导（`ServersView.swift:54-57`），无 CTA 按钮 |
| C4 | 🟢 **计划前提部分过时** | 两阶段加载范式已覆盖至少三处：防火墙、网站监控、**容器**（`ContainersViewModel.swift:50-54` 列表与 Docker 状态并行、`mergeStats` 后台补指标，注释明确"先显示列表，避免等待 stats"）。剩余：Databases/Apps/Certificates/Cronjobs/Backups/Logs/Files/WAF 逐页核对 |
| C5 | 🟡 截断面已固化 | pageSize 全量清单（40 处）已提取：容器 100、数据库 200、防火墙 200×3、文件 200/300、WAF 各 100、网站列表 **20**（`WebsitesViewModel.swift:74`）、AppIntents 200、日志类 500。**修正计划书：容器是 100 非 200；网站列表是 20 非 200**。>200 条真机验证待做 |
| C6 | 🟢 Widget 空态已达标 | `ServerStatusWidget.swift:44-46` 无服务器时显示「请先添加服务器」离线态；30 分钟时间线预算合理（`getTimeline`）。QuickOpsWidget 需同查（也是 Swift 6 报错点，顺手修） |
| C7 | 🟡 待补 | FaceID：设置内开启应用锁，触发即系统弹窗，静态未见预解释页；本地网络预解释随 C1 一并设计 |

---

## 5. Phase D：性能与资源审查发现

| ID | 结论 | 证据与剩余工作 |
|---|---|---|
| D1 | 🟡 **实锤（与计划一致）** | `ServersView.swift:65-72`：页面存在期间每 5s 对**所有**服务器并发 dashboardCurrent，`.task` 在后台不被取消；`OverviewTab.swift:136-143` 同款循环（仅判 `selectedTab == .overview`）。多服务器同秒并发（task group 无相位错峰）、无失败退避。修法计划已备；页面级暂停先例可直接参考 `MonitorView.swift:237` |
| D2 | ⛔ 待 A3 | — |
| D3 | 🟡 静态确认一个真实重复场景 | 用户从首页推入服务器页时：OverviewTab 的 5s 循环条件 `selectedTab == .overview` **仍为真**（push 不改变 Tab 选择），与 ServersView 的 cardMonitor.refresh 同周期对同一服务器各发一次 dashboardCurrent。计划验收口径「同服务器同接口 ≤1 在途」当前不满足 |
| D4 | 🟡 静态确认解码在主线程 | `APIClient.send` 的 `JSONDecoder().decode` 在调用方 actor 执行（`APIClient.swift:152,177`）；工程默认 MainActor 隔离 → pageSize 200/500 的大列表解码占用主线程；`ServerCardMonitor.swift:17,28` 的 task group 子任务也继承 @MainActor。修法：解码移 nonisolated。量化待 Instruments |
| D5 | ✅ **已完成** | 见 §2.2。11 错误 0 警告，同一模式 4 文件。建议直接开启 Swift 6 并清零（≤0.5 天） |
| D6 | 📌 建议 | 接入 MetricKit（MXMetricManager）：Apple 原生、无隐私申报负担、数据仅在本地/用户主动导出，不破坏零遥测立场；ADR 记录后实现约 0.3d。若维持纯零观测，也应在 F3 报告记录豁免理由 |
| D7 | 📌 | 现有 107 用例；B1 审计测试 + D1 状态机 + C5 分页用例落地后自然 ≥120 |

---

## 6. Phase E：合规与发布审查发现

| ID | 结论 | 证据与剩余工作 |
|---|---|---|
| E1 | 🔴 **P0 实锤** | app / PanelShared / PanelWidgets / swiftterm 包**四处均无** PrivacyInfo.xcprivacy。required-reason API 盘点已备好：① UserDefaults/@AppStorage **12 文件** → CA92.1；② `FilesView.swift:341` `attributesOfItem`（文件时间戳）→ C617.1；③ 未发现 system boot time API。NSPrivacyCollectedData：全不收集（零遥测成立——无上报代码、无三方 SDK）。产出：app 与 PanelWidgets 两份清单（PanelWidgets 因链接 PanelShared 同样用到 UserDefaults） |
| E2 | 🟢 代码侧已达标 | ATS 全开确认（`Info.plist:5-9`）；明文 HTTP 的 UI 警示链完整：输入即显橙色警告（`ServerEditView.swift:55-59`）→ 保存二次确认（destructive alert + Haptic.warning）→ 设置级「仅允许 HTTPS」硬开关（SecurityGate，有测试覆盖）。剩余：ATS 立场文档 + 审核备注文案（纯写作） |
| E3 | ✅ 三项全过 | ① 密钥仅 Keychain：`ServerManager.swift:84-116` 敏感字段只进 Keychain，且带旧明文镜像的一次性迁移清除；全仓库 grep 无 UserDefaults 存密钥。② 日志：仅 2 处 os.Logger；`APIClient.swift:169-171` DEBUG-only 打印 path+响应体，**不含 apiKey/token/鉴权头**；`ServerManager.swift:125` keychain 类别。密钥零日志输出 ✅。③ UIFileSharingEnabled：下载先落临时目录（`APIClient.swift:393`），仅在用户于 FilesView/BackupListView **显式下载**后移入 Documents（`FilesView.swift:471`、`BackupListView.swift:232`）——属用户主动行为，密钥/配置不经此路径，可接受并有注释说明 |
| E4 | 🟡 缺失 | Info.plist 无 `ITSAppUsesNonExemptEncryption` → 0.2d 补 `false` |
| E5 | 🔴 未启动 | App 内「关于」仅 版本/API 版本/1Panel 官网（`SettingsTab.swift:198-218`），**无隐私政策链接**；备案、ASC 中国区要求均未启动。R5 提醒：流程数周，若目标含中国区应最先启动 |
| E6 | 🟡 仅中文 | `NSFaceIDUsageDescription` 只有中文（`Info.plist:17`），无 InfoPlist.strings；en 系统设置将显示中文。与 C1 新增文案一并做双语 |
| E7 | 🟡 双写实锤 | `MARKETING_VERSION = 0.1.14`（pbxproj 6 处配置）与 `aboutFallbackVersion = "0.1.14"`（`SettingsTab.swift:122`）双写，本次 v0.1.14 靠手工同步。自动化选型待做（agvtool 或构建脚本注入） |
| E8 | 🔴 实锤（与计划一致，量略多） | archive/ 内 **8 个脚本文件**含 `API_KEY="…"` 形式的真实密钥赋值（值已脱敏核验存在，指向 Parallels 虚拟机 `10.211.55.4:36130` 的测试面板）：`logs/sample_responses.sh`、`sample_responses2.sh`、`fetch_swagger.sh`、`probe_endpoints.sh`、`images/run1.sh`、`get_loc_mess.py`、`doc/get_log_op.py`、`1panel_install_new_app.py`。`git ls-files` 确认**全部已被跟踪入库**。正面：仓库无 .env/.key/.pem 跟踪文件。⚠️ 处置注意：仅轮换密钥+改占位符**不够**——历史 commit 中密钥仍可翻出；要么接受历史暴露（测试虚拟机、已轮换即失效），要么 git 历史改写（影响所有克隆）。需明确决策记录 |
| E9 | ⛔ 流程项 | 提审自查清单在 F 阶段执行；2.5.2 终端边界（本地 UI 渲染用户自己的服务器会话，无可下载执行代码）预判无风险 |

---

## 7. 建议的执行顺序（修订版）

P0（立即，均可先行，不依赖基线）：
1. **C1**：Info.plist 补 `NSLocalNetworkUsageDescription`（双语）+ `APIError.swift:34` 文案补 iOS 本地网络指引 → 真机验证
2. **B1 快赢**：`certificate` → `checkmark.seal`（3 处）+ `SFSymbolAuditTests.swift` 落库
3. **E1**：两份 PrivacyInfo.xcprivacy（盘点数据见 §6-E1，直接抄）
4. **E8**：密钥处置决策（建议：面板侧轮换密钥 + 归档脚本改占位符 + ADR 记录历史暴露与豁免理由）

P1（排期）：
5. **D1+D3 合并修**：轮询状态机（scenePhase 暂停/回前台补拉/相位错峰/退避）+ 服务器页与首页轮询去重
6. **D5**：直接开 Swift 6（11 错误清单见 §2.2）
7. **B8+E6 合并**：20 条 AppIntents/Widget 词条补 en + `PanelIntents.swift:18,43` 硬编码改 L10n + 权限文案双语
8. **E7**：版本号单一来源自动化
9. **E4**：出口合规键（顺手）
10. **D4**：解码线程（配 A2 基线一起做）

P2：B2 字体收敛、B3 一致性核对（工作量已下调）、C3 文案区分度与空态 CTA、C4 逐页核对、C5 截断方案、D2、D6 MetricKit 决策、E2/E5/E9 文档与流程。

---

## 8. 对计划书本身的修正清单

1. **B3 前提过时**：「仅 LoadingStateView 一个统一状态组件」→ 实际已有 LoadErrorStateView/ErrorBanner/ContentUnavailableView(103 处)；任务从"定义组件并替换"改为"形态一致性核对"，1.5d 可缩至 ~0.5-1d
2. **C4 前提过时**：容器页已两阶段化（范式已有三处），逐页核对即可
3. **C5 数字不准**：容器 100（非 200）、网站列表 20（非 200）、意图 200；截断风险实际页面集与计划有出入
4. **B8 范围偏移**：源码硬编码中文 6 处全在 DEBUG-only 页面（Release 不可达）；真正用户可见的 en 缺失是 xcstrings 20 条 AppIntents/Widget 词条 + PanelIntents 2 处硬编码
5. **required-reason 文件数**：14 → 12（不含测试）
6. **scenePhase 描述细化**：页面级监控（MonitorView/ContainerMonitorView）已有暂停先例，可直接复用到 D1 方案

---

## 9. 基线数字表（对计划书 §7 的部分填充）

| 指标 | 基线（v0.1.14） | 备注 |
|---|---|---|
| 包体（单架构 arm64，未压缩 .app） | **17 MB**（主二进制 12MB / Assets.car 3.4MB） | 归档实测；App Store thinning 口径待 A4 正式取数 |
| 全量测试 | **107/107 通过**（24.6s） | iPhone 17 Pro 模拟器，Xcode 26.6 |
| 构建警告 | **0**（默认模式 + Swift 6 模式均验证） | Swift 6 模式另有 11 error（见 D5） |
| SF Symbol 有效率 | 49/50 字面量 | 1 无效：certificate |
| 冷启动→首帧 | ⛔ 待 A1（Instruments） | |
| 14 页遍历后内存 | ⛔ 待 A3 | |
| 后台 10 分钟轮询请求数 | ⛔ 待抓包（静态推断 ≈ 每台服务器 120 次，D1 后应为 0） | 两处循环见 §5-D1 |
| 重页面 hitch 数 | ⛔ 待 A2 | |

---

*评估工具：grep/静态走查 + xcodebuild（test / SWIFT_VERSION=6.0 probe）+ NSImage SF Symbol 校验（macOS 26 与 iOS 26.5 符号集同源）+ 现有 xcarchive 测量。报告证据均可按文中 file:line 复核。*
