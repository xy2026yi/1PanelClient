# 审计修复记录（2026-09-06）

> 依据：`doc/references/project-audit-report-2026-09.md` §7 执行顺序。
> 结果：P0 全部落地、P1 全部落地；**Swift 6 已开启并零错误零警告；全量测试 109/109 通过**
> （107 原有 + 2 个 SF Symbol 审计用例）。
> 需真机/Instruments 的验证项已单独拆出：`doc/references/manual-verification-checklist-2026-09.md`。

## P0 修复

| 项 | 内容 | 落点 |
|---|---|---|
| C1 | `NSLocalNetworkUsageDescription` 补入 app 与 Widget 的 Info.plist（中文基准值 + `en.lproj/InfoPlist.strings` 英文）；连接错误文案补 iOS 真机「设置 → 隐私与安全性 → 本地网络」指引 | `1PanelClient/Info.plist`、`PanelWidgets/Info.plist`、两个 `en.lproj/InfoPlist.strings`、`APIError.swift:30-40`、`Localizable.xcstrings`（词条已替换并带 en） |
| B1 | `certificate` → `checkmark.seal`（3 处：CertificatesTab:178、CAView:34、CAView:133）；`SFSymbolAuditTests.swift` 落库——运行时扫描源码全部 `systemName/systemImage/systemImageName` 字面量，逐个 `UIImage(systemName:)` 断言（iOS 真机语义，替代 NSImage 代理法） | `Features/Certificates/`、`1PanelClientTests/SFSymbolAuditTests.swift` |
| E1 | 两份 `PrivacyInfo.xcprivacy`：app（UserDefaults CA92.1 + FileTimestamp C617.1）、PanelWidgets（UserDefaults CA92.1）；NSPrivacyCollectedData 为空（零遥测）。已验证进包 | `1PanelClient/1PanelClient/PrivacyInfo.xcprivacy`、`PanelWidgets/PrivacyInfo.xcprivacy` |
| E8 | 7 个归档脚本的同一把真实 API 密钥全部移除（.sh 改环境变量 `${1PANEL_API_KEY:?…}`，.py 改占位符）；决策记录 ADR（轮换密钥=待人工、不改写 git 历史） | `archive/logs/*.sh`、`archive/doc/*.py`、`docs/adr-0001-e8-archive-key-exposure.md` |

### B1 的重要新发现

审计测试首跑即抓出 **7 个报告未发现的无效 symbol**（NSImage 代理法在 macOS/iOS 符号集上有出入，
印证了报告「换成 UIImage 断言」的判断）。合计 9 处使用点已全部替换为 SF Symbols 1.0 时代的稳妥名：

| 无效名 | 替换 | 使用点 |
|---|---|---|
| `square.and.at.arrowcommand` | `terminal` | QuickCommandsView 空态 ×2 |
| `list.bullet.rectangle.shield` | `shield` | WAF 通用规则空态 |
| `sitemap` | `globe` | WAF 网站设置空态 |
| `ipaddress` | `number` | WAF IP 规则空态 |
| `arrow.up.circle.slash` | `arrow.up.circle` | 应用升级无版本空态 |
| `waveform.badge.eye` | `waveform` | 网站日志「追踪」开关 |
| `arrow.uturn.turn.right` | `arrow.uturn.right` | 网站重定向空态 + 行标签 ×2 |

## P1 修复

| 项 | 内容 | 落点 |
|---|---|---|
| D1+D3 | 新增 `adaptivePolling` 修饰器：scenePhase 非 active 或附加条件不满足时暂停；恢复运行态当秒补拉一次；页面消失随 `.task` 取消。首页轮询条件收紧为「首页 Tab 且处于根页面」——推入服务器页后由服务器页全量轮询接管（同服务器同接口不再双发，D3）。`ServerCardMonitor` 增加多机 250ms 相位错峰 + 连续失败指数退避（跳过 1/2/4 轮封顶，成功即恢复；下拉刷新 `force: true` 清退避强制重试） | `Features/Overview/AdaptivePolling.swift`（新）、`OverviewTab.swift:135-142`、`ServersView.swift:59-71`、`ServerCardMonitor.swift` |
| D5 | `SWIFT_VERSION` 6 处配置全部 5.0 → 6.0；11 个错误清零（见下方偏差说明）；Swift 6 全新构建 **0 error 0 warning** | pbxproj + 见下 |
| B8+E6 | `Localizable.xcstrings` 补 20 条 AppIntents/Widget 词条的 en 翻译（缺 en 的中文词条已清零）；FaceID/本地网络权限文案双语（InfoPlist.strings） | `Localizable.xcstrings`、两个 `en.lproj/InfoPlist.strings` |
| E7 | 版本号单一来源 = pbxproj `MARKETING_VERSION`（构建注入 `CFBundleShortVersionString`）；删除 `aboutFallbackVersion` 双写，读取失败兜底 `0.0.0` | `SettingsTab.swift:121-123,160,201` |
| E4 | `ITSAppUsesNonExemptEncryption = false` | `1PanelClient/Info.plist` |
| D4 | `APIClient.send` 两处 decode 改经 `nonisolated static func decode`（async → 全局并发执行器），pageSize 200/500 大列表解码不再占用主 actor | `APIClient.swift:151-153,177-180,186-189` |

## 与报告建议的偏差（及原因）

1. **PanelIntents `typeDisplayRepresentation` 未改 L10n.t**：报告 §7 建议硬编码改 L10n，但该文件头注释
   明确了既有设计——静态意图元数据走系统语言（LocalizedStringResource 查 Localizable 表），运行时
   dialog 才走 L10n（应用内语言）。缺失英文的真实原因是词条表没有 en 条目；补齐词条即修复，
   改 L10n.t 反而会让快捷指令 UI 跟随应用内语言、与同文件其他静态文案行为不一致。
2. **Swift 6 修复用计算属性而非 @MainActor**：实测 iOS 26 SDK 的 `AppEntity.defaultQuery`、
   `TypeDisplayRepresentable` 协议要求非隔离见证，`@MainActor` 会报 "conformance crosses into
   main actor-isolated code"；改为 `static var x { X() }` 计算属性（无静态存储即无并发安全问题）。
   `QuickOpsConfig.title/description` 则按 PanelIntents 五个意图的既有 `static let` 写法对齐。
   `L10n` 用 `@unchecked Sendable`（全部可变状态在 NSLock 内）替代 `nonisolated(unsafe)`，等效但范围更小。
3. **Swift 6 切换引入的 1 个新警告**（FilesView `asyncAfter` 传非 Sendable 闭包）已一并修复
   （改 `Task { @MainActor }` + sleep，语义不变）。

## P2 修复（2026-09-06 第二轮，上架准备口径：不提审、侧载为主）

| 项 | 内容 | 落点 |
|---|---|---|
| D6 | 接入 MetricKit 本地诊断（ADR-0002）：MXMetricManager 订阅落盘 `Application Support/Metrics/`（保留 30 天自动清理），设置-关于-「诊断数据（本地）」可列表 + 分享导出；零上报、隐私清单不变 | `PanelShared/Core/Metrics/MetricKitSubscriber.swift`、`_PanelClientApp.swift`、`SettingsTab.swift`、`doc/adr/adr-0002-d6-metrickit-local-diagnostics.md` |
| E2 | ATS 立场文档 + 提审备注中英文模板（纯写作，未来提审直接取用） | `doc/references/ats-stance-and-review-notes.md` |
| E5 | App 内隐私政策：中文政策文档 + 关于页入口（URL 暂指仓库 docs 地址，上架前换正式页）；**中国区备案暂缓**，上架前数周再启动 | `doc/privacy-policy.md`、`SettingsTab.swift` |
| C3 | 超时与不可达文案区分：`timedOut` 单独成文（端口/防火墙 + 本地网络权限指引——真机权限被拒也常表现为超时，故指引保留）；其余不可达错误沿用原长文案。服务器页无服务器空态补 ContentUnavailableView + 「添加服务器」CTA | `APIError.swift`、`ServersView.swift` |
| B2 | 固定字号收敛：实际 `.font(.system(size:))` 仅 26 处（审计的 118 处含 97 处语义档，本就支持 Dynamic Type）。26 处统一改 `Font.panelScaled`（UIFontMetrics 按字号就近挂 TextStyle，默认视觉不变、缩放生效）；替换后 grep 归零 | `PanelShared/Shared/PanelFont.swift` 及 26 处调用点 |
| B3 | 「暂无」空态统一：视图上下文 6 处纯 Text 改 ContentUnavailableView（LogsView×2、CronjobRecordViews、CertificatesTab、WebsiteConfigViews 账号区）。**保留 Text 的合理形态**（豁免）：表单/Picker 内占位（CreateDatabaseView×3、ContainerImagesView、CreateWebsiteView）、固定高度图表占位（MonitorView×2、ContainerMonitorView、WebsiteMonitorViews×3）、Widget/Intents 非视图上下文 | 各 Features 视图 |
| — | 动态选择 symbol 人工过目：复查全部三元符号选择 33 处（报告口径 31）——均为 `eye/chevron/checkmark.circle/folder` 等有效名且语义合理，**无字符串插值拼接**；字面量部分继续由 `SFSymbolAuditTests` 静态审计（本轮新增符号已随测试通过） | 无代码改动 |

P2 验证：`1PanelClient`/`PanelWidgets` 两 target 构建零错误零警告；测试 109/109 通过。

## 真机验证修复（2026-09-07 第三轮，直装真机反馈）

| 项 | 内容 | 落点 |
|---|---|---|
| W1 小组件空态误报 | 真机直装后小组件显示「离线：请先添加服务器」但已有服务器。根因非数据通道（App Group / 共享 Keychain / 镜像均正常、entitlements 两 target 一致），而是**主 App 从不调用 `WidgetCenter` 重载**：小组件时间线 30 分钟策略下靠系统预算自行刷新（可能拖数小时；重装 App 后桌面已有小组件甚至冻结在旧时间线），期间一直显示旧空态。修复：`ServerManager` 在冷启动、`persistServers()`（增/改/删）、`setCurrent()`（切换当前服务器）后 `reloadAllTimelines()`，扩展进程内跳过；另在应用内语言切换后重载（小组件文案跟随语言） | `PanelShared/Core/Storage/ServerManager.swift`、`1PanelClient/ContentView.swift` |
| L1 应用锁 FaceID 取消循环 | 真机直装后取消人脸认证会无限重弹。根因：FaceID 系统弹窗本身让 app 走一轮 inactive→active，`LockScreenView` 监听回 active 即补弹，取消→回 active→再弹死循环（原 `biometricInFlight` 标记有竞态挡不住；侧载 LiveContainer 因 scenePhase 传播滞后未暴露）。修复：新增 `biometricAutoPresented`——每轮前台至多自动弹一次，取消/失败后仅用户点「解锁」触发；真正进过后台（.background）或用户主动切回生物识别面板才重置 | `1PanelClient/Features/Settings/AppLock.swift` |
| L2 熄屏唤醒手机 | 真机直装：App 前台无操作休眠锁屏后，手机会自己亮屏弹出 FaceID（其它 App 均为设备解锁后才出现）。根因：熄屏瞬间 scenePhase 会**瞬时回弹一次 active**，此时 applicationState 与受保护数据尚未落到已锁定态，`lockedByDeactivation` 又在收到 active 时即被清除，守卫全放行 → 验证弹窗在系统锁屏上弹出并唤醒屏幕。修复：收到 active 不再清标记；`autoBiometricUnlock` 改为**延时 0.8s 复核**（回弹在 1s 内落回非活跃态被拦下、不消耗本轮自动弹次数；真回前台持续活跃则清除标记并弹窗）——设备解锁后照常自动弹，时序对齐其它 App。⚠️ F2 复验发现回归：标记仍留在首道守卫导致「解锁回前台」永远不自动弹，已从守卫移除（标记仅延时复核通过后清除） | `1PanelClient/Features/Settings/AppLock.swift` |
| W1b 新装小组件刷新慢 | F2 复验：新装 App 后小组件刷新明显慢于秒级——重装后系统可能丢弃此前的 reload 请求，拖到分钟级。修复：`ContentView` 回前台（scenePhase → active）时补一次 `reloadAllTimelines` 兜底，请求由系统合并调度 | `1PanelClient/ContentView.swift` |
| W3 小组件永远离线（ATS） | 三轮复验（Xcode 直装 + 添加服务器 + 桌面小组件 + 等 30s）仍显示离线——reload 机制已生效，但时间线条目本身连接失败。根因：**小组件扩展进程用自己的 Info.plist，缺 ATS 豁免**（主 App 有 `NSAllowsArbitraryLoads`），所有 `http://` 明文面板地址的请求在扩展进程被 ATS 掐断（-1022），与 App Group/Keychain/时间线均无关。修复：`PanelWidgets/Info.plist` 补齐与主 App 一致的 `NSAppTransportSecurity`（已验证进包） | `PanelWidgets/Info.plist` |
| W2 底部栏丢失复发（首页/设置） | 真机反馈首页底部栏仍会丢失。根因与 eefa651 管理 Tab 同源但未修完：首页/设置仍用 `navigationDestination(isPresented:)` + onChange 同步 atRoot，iOS 26 back 返回后绑定写回延迟甚至丢失，onChange 收不到 pop，atRoot 卡 false。修复：三个 Tab 导航路径统一由 MainTabView 持有，`showTabBar` 直接由路径计数计算（纯函数、单一真源），删除三个 atRoot 镜像 @State 与 0.2s 对账 Timer；首页/设置改 path 驱动导航（route enum），设置页内二级推入（隐私政策/诊断）一并 path 化 | `MainTabView.swift`、`OverviewTab.swift`、`SettingsTab.swift` |
| E5-2 隐私政策本地页 | 「设置 → 关于 → 隐私政策」由网页链接改为 App 内本地页（离线可读、随应用内语言双语），页底保留在线版入口；新增 28 条 en 词条。E5-3 走查发现在线版/Issue 链接指向占位仓库，已改指真实仓库 `xy2026yi/1PanelClient` 的 `doc/privacy-policy.md`（对外文档目录为 git 跟踪的 `doc/`；`docs/` 被 gitignore 仅本地） | `PrivacyPolicyView.swift`（新）、`SettingsTab.swift`、`Localizable.xcstrings`、`doc/privacy-policy.md` |
| C5 分页加载 | 真机确认的静默截断补齐（防火墙 215 条只显示 200、操作日志 509 条只显示 100）：防火墙三段（端口规则/端口转发/IP 规则）与操作日志、访问日志列表改为「首屏一页 + 滚动到底自动追加下一页」——末行与加载行双触发、组合 id 去重防跨页重复、首屏重载后丢弃过期追加、段头计数改显面板总数；追加失败不打断列表（下拉刷新重试）。系统/SSH/网站日志为文件尾部读取语义（latest=true），不属分页截断，维持现状。任务中心原有同款分页不动 | `FirewallView.swift`、`LogsView.swift`（操作/访问日志） |

第三轮验证：两 target 构建零错误零警告；测试 109/109 通过。四项待真机复验（见 checklist D 节 F2 备注、C5 结果行）。

## 第四轮（2026-09-07）：C4 逐页核对 + C5 剩余主列表分页

**C4 逐页两阶段核对结论（全部达标，其中一处实修）：**

| 页面 | 现状 | 结论 |
|---|---|---|
| 防火墙 / 容器 / 网站监控 | 列表先行，进程名 / stats / 监控数据后台补齐（审计已确认） | ✅ |
| 数据库系统详情 | 六路请求并行——**但 `async let` 与直接 await 混用导致每个请求实际发出两遍**（check/connInfo/remote/数据库列表/用户列表 ×2），已改为单次全并行 | 🔧 已修 |
| 应用 | 全量 + 可更新 + 忽略三请求并行合并，忽略列表失败降级不阻断 | ✅ |
| 证书 / 计划任务 / 备份账号 / 操作/访问日志 / 文件 | 主列表单请求即首屏，辅助数据按需加载 | ✅ |

**C5 分页补齐（剩余主列表，同第三轮模式——末行+加载行双触发、id 去重、过期追加丢弃）：**

| 列表 | 首屏 | 落点 |
|---|---|---|
| 网站（原 20/页） | 20/页 + 滚动追加，沿用搜索词翻页 | `WebsitesViewModel`、`WebsitesTab` |
| 容器（原 100/页） | 100/页 + 滚动追加，追加后补 mergeStats 指标 | `ContainersViewModel`、`ContainersTab` |
| 应用（原 100/页） | 100/页 + 滚动追加，追加页重拉可更新/忽略映射合并 canUpdate 徽章（合并逻辑抽 `mergeUpdateState` 与首屏共用） | `AppsViewModel`、`AppsTab` |
| 数据库（原 200/页） | 200/页 + 滚动追加 | `DatabasesView`（DatabaseSystemViewModel + 列表区） |

第四轮验证：构建零错误零警告；测试 109/109 通过。剩余截断面：文件管理器（目录 >200）、WAF 各列表（100）、AppIntents 参数解析（200）——数据量未触顶，暂不动，触顶后照同款模式补齐。

> 补充（2026-09-07 B5 无障碍分诊，报告 `logs/Audit/*.html` 五页）：首页 42 条 Dynamic Type
> 中逮到 B2 漏网的真固定字号 1 处——`RingStatView` 百分比文字赋给 Font 属性的字面
> `.system(size: 10/13)`（B2 当时按 `.font(.system(size:` 前缀 grep，属性赋值形态漏掉），
> 已改 `panelScaled`；全仓同类仅此一处。其余真问题一并修复：
> ① Hit Region 5 处——监控页三个图表展开按钮 15×9、防火墙状态卡展开箭头 11×7、
> 锁屏底部「使用密码/面容 ID 解锁」切换按钮高 18pt，统一扩到 44×44 命中区（视觉不变）；
> ② Element Description——锁屏顶部生物识别图标改 `accessibilityHidden`（下方「已锁定」
> 文本已表意）、删除键 Image 层补「删除」标签（审计器读到符号名 delete.left）、终端
> SwiftTerm TerminalView 补 `isAccessibilityElement` + 「终端」标签。Contrast/Dynamic Type
> 其余项为材质混色误报与固定容器/系统灰权衡（详见 checklist B5 结果行），不修。

## 仍未做（2026-09-07 第四轮后更新：代码/验证侧已收口，仅剩上架链路项）

~~C4 逐页两阶段核对~~（第四轮完成，全部达标；一处实修：数据库系统详情页请求双发改单次全并行）；
~~C5 截断方案~~（第三、四轮已补齐防火墙三段 + 操作/访问日志 + 网站/容器/应用/数据库主列表的
滚动追加分页；剩余面文件管理器 >200、WAF 各列表 100、AppIntents 参数 200——数据量未触顶，
触顶后照同款模式补齐）；~~D2 内存基线~~（2026-09-07 真机记录、数字健康，见 checklist A3/D2；
A2 hitch 基线剩系统日志/数据库两列表，有数据时顺手补，暂缓）。
E1 ASC 隐私页/TestFlight 验证、E4 出口合规生效确认、E9 提审自查清单、中国区备案实质流程
——以上与 App Store 提审链路绑定，**当前口径为只做上架准备、不提审（侧载为主）**，上架决定做出后再启动。

---

## 2026-09-16 四维审查（UI 一致性 / iPad / 本地化 / 弹窗）P1 修复

> 依据：`archive/docs/project-audit-report-2026-09-16.md` §6 P1 清单。
> 结果：**P1 全部落地；全量测试 242 用例 / 44 套件通过（Swift Testing，iPhone 17 Pro 模拟器）；构建零错误**。

| 项 | 内容 | 落点 |
|---|---|---|
| 弹窗-9 | 网站详情页补加载失败分支：`WebsitesViewModel` 新增 `detailErrorMessage`（与列表页 `errorMessage` 分离防串扰），`loadDetail` 失败改走该通道不再弹 alert；视图层补 `LoadErrorStateView` + 重试分支（此前失败后静默回落两行基本信息、无恢复入口） | `WebsitesViewModel.swift:15-18,383-402`、`WebsiteDetailView.swift:105-110` |
| 弹窗-2（R1 双强度） | 列表长按单站删除由一键 alert 改为与详情页同款 `WebsiteDeleteConfirmSheet`（输入域名 + 连带删除选项；Haptic.warning 由 TextInputConfirmSheet 内建） | `WebsitesTab.swift:213-217` |
| UI-9 | 错误日志类型色 `.orange` → `.statusError`（语义颠倒修正） | `WebsiteLogViews.swift:37` |
| UI-克隆 | 6 处手绘「加载失败+wifi.exclamationmark+重试」全部替换为 `LoadErrorStateView`：操作/访问/系统/SSH 日志 + 网站日志选择器 + 防火墙端口白名单编辑 | `LogsView.swift` ×5、`FirewallView.swift:1819-1824` |
| UI-克隆 | `StatusBadge` 增加可选 `label` 前缀参数（键值两段式胶囊：「键」secondary「值」主样式，既有 110+ 调用点零影响）；`BackupListView.metaBadge` 手绘克隆改走共享组件 | `CommonComponents.swift:307-339`、`BackupListView.swift:587-589` |
| 弹窗-标准成文 | `UI设计规范` v1.0→v1.1：§一 补 R1 判定细则（四条）、「列表/详情/批量同强度」「批量 ≥ 单删」两条硬规则、存量偏差对齐清单（容器→R1、批量网站→升强度等待办 P2）；文档从 `archive/doc/`（gitignore）移回 `doc/`（源码引用路径，随库版本控制） | `doc/UI设计规范.md` |

### 备注

- `WebsitesTab` 原 alert 的词条「将删除网站「%@」及其配置，该操作无法回滚，是否继续？」随代码删除转为死词条，归入 P3 死词条清理（现存量 69+1 条）。
- 未动的 P2/P3 债（iPad 限宽 ~30 处、Widget 语言跨进程、DateFormatter locale、令牌治理等）见报告 §6 排期建议与 `1panel-upstream-adaptation-roadmap-2026-09.md` M0-M3。

## 2026-09-16 四维审查 P2/P3 批量清偿

> 结果：**P2 六个主题全部落地；P3 完成可自动化项；全量测试 243 用例 / 44 套件通过（+1 动态符号防线）；构建零警告**。

### P2

| 主题 | 内容 | 落点 |
|---|---|---|
| A 本地化运行时 | ① 语言偏好迁 App Group（Widget 进程可读，一次性迁移；`AppGroup` 静态成员 nonisolated 化）② 硬编码中文 4 处（进程排序/分段 Picker rawValue 包 `L10n.t`、WAF 图表轴标签）③ 展示类 DateFormatter×7 + 相对时间×2 + compactName×2 全部接 `L10n.locale`（App 内语言≠系统语言时不再中英混排）④ AppShortcut shortTitle「重启容器」补词条 | `L10n.swift`、`KeychainStore.swift`、`ProcessView.swift`、`WAFMonitorViews.swift`、7 个 formatter 文件、`ServerStatusWidget.swift`、xcstrings |
| B 弹窗健壮性 | AddNodeView / SnapshotCreateView 提交中 `interactiveDismissDisabled`（覆盖 4 处挂载场景）；OverviewTab 升级成功改 toast、错误保留 alert；AppStoreTab `installSuccess` 死状态清理（成功路径早已走进度页） | `AddNodeView.swift`、`SnapshotViews.swift`、`OverviewTab.swift`、`AppStoreTab.swift` |
| C 模型层语义色 | `Website.statusColor` / `BackupRecord.statusColor` 接入语义令牌（语义色令牌 nonisolated 化供后台解码上下文访问） | `Website.swift`、`BackupModels.swift`、`DesignTokens.swift` |
| D iPad 限宽收割 | **18 处**：AI 七频道配置页 formWidthLimit（微信/QQ/企业微信/钉钉/飞书/TG/Discord）+ Firewall 三表单（创建/修改端口规则、链规则）+ 日志/预览 8 处 contentWidthLimit(860)（容器日志/执行日志/任务进度/Compose Diff×2/参数预览/文件预览/配置预览）。ModelCardSheet 为 sheet 形态不需限宽（审查误报） | `AIAgentChannelViews`、`FirewallView`、`ContainerDetailView`、`CronjobRecordViews`、`TaskProgressView`、`AppParamsViews`、`FilePreviewView`、`AIAgentSettingsViews` |
| E 令牌治理 | dataMonospaced 家族扩至六档（+Body/Footnote/Headline/Callout），**176 处 mono 硬编码批量替换**；Radius 三档落地（**42 处** `cornerRadius: 8/12/16` → 令牌）；WebsiteNginxViews 两处废弃 `.cornerRadius()` 修饰符 → clipShape | 全库 88 文件、`DesignTokens.swift` |
| F 三态收尾 | 新增共享 `ChartEmptyPlaceholder`（统一 Monitor/GPU/容器监控四处图表空位，原各自手搓且高度不一）；**30 处** Section 裸转圈 → `LoadingStateView(compact:)`；`FollowLatestButton` 共享组件（Compose/应用日志逐字复制的胶囊归一） | `CommonComponents.swift`、21 文件 |

### P3

| 项 | 内容 |
|---|---|
| xcstrings 清理 | 死词条 **69 条**删除（转义感知匹配 + 排除 AppIntents `${}` 参数化键防误删）；stale **14 条** → manual（防 Xcode 图形化编辑时清除在用词条）；术语统一：「计划任务」Scheduled Tasks → **Cronjobs**（对齐 1Panel 英文界面与既有组合词条）×3 |
| ErrorBanner 收敛 | FirewallView 整页降级改 LoadErrorStateView（ErrorBanner 仅剩 OverviewTab 一处规范内使用） |
| 实体操作面板规范成文 | ActionBottomSheet（纯菜单）/ FirewallActionSheet·ServerActionsSheet（信息头+分组操作）两种形态判据写入规范 §二——不强行合一（需扩 24 处调用点的共享组件 API 且无法视觉验证），以规范收口 |
| 动态 SF Symbol 防线 | SFSymbolAuditTests 新增 `dynamicSymbolNames` 人工清单测试（60+ 动态名：fileIcon/systemIcon/biometryIcon/全库三元对），后续新增动态分支同步补清单 |
| size 字体清零 | OverviewTab×2、WebsitesTab×1 `.system(size:)` → `panelScaled`（B2 声明与现实对齐） |

### 明示不修（记录在案）

- QuickOpsWidget 补 small/large 档：新 Widget 布局属视觉设计决策，需真机验证后单独做
- hover/键盘快捷键扩展、isPresented 177 处二级页迁移：长期打磨项，非本轮范围
- WebsiteHTTPSView 胶囊、SettingsTab 描边圆徽章：与 StatusBadge/IconBadge 语义或视觉形态不同（toggle/描边），非同款克隆，保留

## 2026-09-17 M1：防火墙对齐 v2.3.0 重构 API（代码侧完成，抓包验证待办）

> 依据：`doc/references/v2.3.0-upstream-diff.md`（上游源码 diff）。结果：**257 用例 / 46 套件通过**（+7 防火墙 V2 解码测试、-1 旧链规则套件）；构建零警告。

| 项 | 内容 |
|---|---|
| 模型整替 | `Models/Firewall.swift` 全量重写为 v2.3.0 契约（形状来源 = 上游 Go DTO json tag 全量映射）：子系统状态/统一规则（scope+states 五态）/转发子域/三组后端设置/Docker 端口守护 20+ 类型，字段全可选 + 稳定行键（external 规则用 instanceKey/内容组合防列表闪动） |
| 端点重写 | `APIEndpoints` 防火墙段 15 旧 case → 19 新 case（rules 统一命名空间/forward 子域/settings/docker 全家），消灭 `/firewall/port` 同路径改义隐患 |
| 视图整替 | `FirewallView.swift`（2665→1528 行）+ 新 `FirewallForms.swift`：状态卡（生命周期+基础链初始化/绑定+ping 开关）+ 四段（规则：states/families 筛选+分页+滑动删除；转发：子系统状态+启用+编辑=remove+add 同请求；Docker 守护：总览/容器分组/孤立策略/初始化绑定同步；设置：三组后端 select/initialize/cleanup+白名单任务式）。旧端口/转发/IP/链规则四段模型删除 |
| L2 版本门禁 | 防火墙页首请求 404 → 「面板版本过低，需 v2.3.0+」整页提示（决策：不做 v2.2.x 双路径，对齐「跟随最新」策略） |
| 任务式操作 | init-base/启用转发/白名单/Docker 初始化接 TaskProgressView 进度页 |
| 词条 | 新增 67 条（含 en），防火墙页全量本地化 |
| 测试 | `FirewallV2ModelsTests` 7 例（合成夹具：子系统状态/清单 managed+external 混合/创建任务式响应/转发 PageEnvelope/设置三组/Docker 总览/scope 构造三分支）；既有白名单解析测试抓住新解析器的 **CRLF 字素簇 bug**（Swift 中 CR+LF 是单个 Character，`== "\n"` 匹配不上，改 `isNewline`）——顺手验证了测试防线的价值 |
| 基线 | `PanelVersionTools.adaptedBaseline` → v2.3.0；README 双语适配声明更新 |

**待办（记录在案）**：① v2.3.0 真机抓包逐端点核对（重点 `/firewall/base` name 取值、rules/search 请求回显、docker/ports 真实形状）→ 真实样本替换合成夹具；② 推迟项：rules/sync 全流程、adopt、reorder、reset、native/detail、docker policy upsert 表单（运维级高级功能，后续按需）。

## 2026-09-17 M2：模型加固 + L2 分型 + diff 脚本化

> 全量测试 **268 用例 / 47 套件通过**（+11 容错解码回归）。

| 项 | 内容 |
|---|---|
| 盘点修正 | 审计报告「Database.swift 88 非可选最危险」经精确复核为高估——其中大部分是 **Encodable 请求体**（客户端构造、不参与解码）。真实解码面：Database/Container/ContainerResource/Snapshot 四文件共 **12 个 Decodable 结构 / 约 20 个非可选存储字段** |
| L1 容错解码 | 新增 `DecodeHelpers.decodeDefault`（缺失/null/类型漂移回退默认值）；落至 15 个结构：DatabaseSystem、FormatOption、Container、ContainerRepo、ContainerImage、ContainerInfo、ContainerOption、ContainerNetworkInfo/PortInfo/VolumeInfo（保留 memberwise init 供回写构造）、ContainerNetwork/Volume/Compose/ComposeItem/Template、SnapshotItem、SwapDetail、PanelRelease。消费端零改动 |
| ContainerInfo 决策 | 回写 merge 不做：update 请求为表单形状（cmdStr/imageInput 等，与 Web 端一致），上游新增 info 字段表现为功能缺口（月度 SOP 对齐项）而非数据损坏；结论已注释在模型头 |
| L2 分型 | `APIError.isEndpointMissing`（404 → 调用方降级「面板版本不支持」）；防火墙 v2.3.0 门禁改用该助手，后续新端点采纳时同款接入 |
| diff 脚本化 | `scripts/upstream_api_diff.py`：两 tag 源码包下载（缓存）+ 路由对照 + DTO 类型增删，`--module` 过滤、`--out` 报告（限 cwd 内，tag 白名单 + tar 成员校验防路径穿越，mimosa 复核通过）；已对 v2.2.5→v2.3.0 跑通并与 M1 手工结论吻合（新增 24/删除 11）。**已知局限**：同名路径换 handler 不可见（/firewall/port 改义类），报告头已注明需人工复核 handler diff |

## 2026-09-17 M1 收尾：v2.3.0 防火墙真机抓包核对闭环

> 全量测试 **275 用例 / 48 套件通过**（+7 真实样本回归）。

依据 `logs/防火墙_v2.3.0.md` + `iptables/nftables/ufw.md`（iptables 后端全流程 + 设置/白名单/后端切换）逐端点核对，修正实现偏差 11 项：

| 类别 | 修正 |
|---|---|
| 会毁功能的 | ① 转发 operate 实为任务式 `{taskID,queued}`（原按空响应解码必报「接口未返回数据」）② docker bind/unbind 返回 null（原统一按任务式解同样报错）——两者分开解码 ③ Docker 总览实际为平铺 `endpoints`（portGroups 空），渲染取并集 |
| 请求口径 | ④ rules/search 需带 `scopes`（iptables/nftables 六链 + excludeChains；ufw 单链 inet/incoming）⑤ 创建 items 需 `sourceKind:"user"` ⑥ 转发 remove 需整行回显（扩全字段 + `.remove(rule)`）⑦ 白名单提交为 JSON 数组字符串 |
| 模型补齐 | ⑧ observed 补 marker/locator ⑨ update 补 orderIndex（仅改优先级）⑩ 白名单条目型 + 双格式解析（初始逗号串/编辑后 JSON 串） |
| UI 判据 | ⑪ 转发启用判据用 isInit（isActive 恒 false）；规则表单协议对齐 Web 四档 + 编辑态优先级字段；白名单改结构化行编辑器；转发表单补地址族选择 |

真实抓包样本固化为 `FirewallV2CaptureRegressionTests` 7 例（设置/转发清单/Docker 总览/规则清单/作用域构造/整行回显编码/白名单双格式往返）。遗留解析函数上移 `Models/Firewall.swift`（PanelShared 自包含，Widget target 可见）。**M1 至此完全闭环**（含外部验证）。

## 2026-09-17 抓包内功能补齐：规则同步 / 重置 / Docker 策略表单

> 全量测试 **279 用例 / 49 套件通过**（+4 同步与策略回归）。

| 功能 | 内容 |
|---|---|
| 规则同步 | `FirewallSyncPreviewView`：preview（ready/existing/removed/blocked 计数 + 待同步清单）→ 确认执行 `rules/sync`（任务式 → 进度页）；规则段（system）与转发段（forwarding）入口；模型 FirewallRuleSyncRequest/Preview/Item/Result（displayToken 按子系统取主标识） |
| 规则重置 | R1 输入后端名确认（对齐 Web「请手动输入 iptables」）→ `rules/reset {provider}` → `{removed,disabled}` toast + 状态重拉 |
| Docker 守护重置 | `settings/operate {subsystem:docker, operation:cleanup}`（抓包口径），同款 R1 确认；Docker 段操作行补重置按钮 |
| Docker 策略表单 | `DockerPolicyFormView`：端点信息头 + 三模式（deny_sources/allow_sources/deny_all）+ 来源行编辑 + 备注 → `policies/batch`（任务式）；端点行点击进入；managementTarget=host_firewall 的端点给说明提示不进表单 |
| 端点 | 枚举 +3 case（rules/sync/preview、rules/sync、rules/reset） |
| 词条 | +24（含 en） |
| 测试 | 同步预览真实样本（system ready/existing）、转发侧 forwardRule 条目、策略编码（JSONSerialization 结构断言——JSONEncoder 键序不稳定，多键子串 contains 是地雷）、重置响应 |

**防火墙模块功能面至此与抓包覆盖面完全对齐**。仍推迟（抓包未覆盖或低频）：rules/adopt 纳管、reorder 拖拽排序、native/detail 原文查看、导出/导入。

## 2026-09-17 Mimosa 完整深度扫描归档

- scanId：`scan-2026-09-17T05-58-45.561Z-37f843001e69`
- 封印：`sha256:0e9524ff389c793838d3d0a75ebac0fbce72cc4f218fc0440f12d699cd7fd5da`
- 结果：**findings 0；依赖风险 0（completion=not_applicable）**
- 覆盖当日全部提交（M0/M1 含抓包闭环/M2/功能补齐，3343dd4…b6a3b22），
  此前 git 钩子持续提示的「library_source/callgraph 不完整」告警就此闭环

## 2026-09-17 M2 收尾：Swagger 源 + 长尾加固 + 信封收编

> 全量测试 **284 用例 / 50 套件通过**（+5 长尾加固回归）。

| 项 | 内容 |
|---|---|
| Swagger diff 脚本 | `scripts/swagger_api_diff.py`：两版 Swagger 文档对比（路径/方法增删 + **同路径契约变化**（operationId/请求/响应 $ref 改义）+ 受影响 DTO 字段级 diff）。用 v2.2.5 archive 版 vs v2.3.0 实抓版验证：防火墙结论与源码 diff/抓包一致，且**抓到源码 diff 盲区的非防火墙同路径改义 5 处，逐一核对全部无碍**（SSH 客户端已是新式、terminal 纯增量、其余同构改名）。局限：旧版注解不全，「新增」= 真新增 ∪ 新补注解，已写入报告头 |
| 长尾加固 | 二代生成器（缩进感知/嵌套安全/键映射保留/可选正确分类）对 19 个结构生成 decodeDefault 容错 init：AIAgent 系 6、Cronjob 系 4、Website 系 3、OpenResty 系 2、AppStore 系 4。自定义键名（protocol/IPV6/ID）全保留；AIHermesChatSession 补显式 memberwise（自定义 init 抑制合成构造器的连带修复）|
| 信封收编 | AppSearchResponse → PageEnvelope（total null/缺失防御）|
| CronjobTransferItem 评估 | **维持现状不加固**：导入导出往返模型，非可选字段是编码侧形状要求；导入失败显式报错正是传输功能想要的语义（对比列表页静默整页失败），与 L1 加固目标相反 |

**M2 至此全部完成**（三源工具齐备：源码 diff + Swagger diff + 抓包工作流）。

## 2026-09-17 防火墙低频项 + 审查 P3 批

> 全量测试 **288 用例 / 51 套件通过**（+4 低频操作回归）。

### 防火墙低频项（抓包/前端契约补齐，功能面全覆盖）

| 功能 | 实现 |
|---|---|
| 纳管 | external/drifted 行 contextMenu「纳管」→ `rules/adopt {scope, instanceKey}`（instanceKey 取 observed 侧） |
| 排序 | manageable 行 contextMenu「上移/下移」→ `rules/reorder {uuid, targetPosition}`（按 observed.locator.position ±1；注：Web 端排序走 update.orderIndex，本端点语义未经抓包验证，失败以错误 alert 呈现——模型注释已注明） |
| 原文查看 | 全部行 contextMenu「查看原文」→ 优先 observed.raw，否则 `rules/native/detail`（zone_service/ufw_application）；等宽展示 + 复制 |
| 导入 | 工具栏「导入规则」→ fileImporter(JSON) 解析 → 勾选清单（全选/全不选）→ `rules` sourceKind:"imported"（任务式进度页） |
| 导出 | 工具栏「导出规则」→ 对齐 Web：**本地组 JSON 无服务端端点**（manageable 且非 protected，去 uuid），写临时文件 `1panel-firewall-rules-<ts>.json` → ShareLink 分享面板 |
| 端点/模型 | +3 case（adopt/reorder/native/detail）+ 3 请求型；词条 +14 |

### 审查 P3 批

- QuickOpsWidget 补 **systemSmall（3 行）/systemLarge（10 行）**，与 ServerStatusWidget 三档对齐
- SettingsTab 关于行手绘描边圆徽章 → IconBadge(34, Radius.small)
- AIAgentDetailView 操作网格写死列数 → gridColumns 语义化（接 iPad 适配体系）
- EllipsisMenu 弹层支持 **Esc 关闭**（iPad 外接键盘；隐藏 cancelAction 按钮实现）

**审查报告（2026-09-16）全部 P1/P2/P3 至此闭环**。剩余长期项仅 isPresentated 177 处二级页迁移（记录在案，随模块迭代）。

## 2026-09-17 wget 三件套补齐（停止 / 记录清理 / 状态展示）

> 依据用户抓包（logs）：POST /files/wget → key、WS /files/wget/process（含 status 字段）、POST /files/wget/stop。
> 全量测试 **291 用例 / 52 套件通过**（+3 wget 模型回归）。

| 项 | 内容 |
|---|---|
| 端点 | +2 case：filesWgetStop（停止指定下载）、filesWgetRecordRemove（清除已完成记录——Web 端下载弹窗的**自动保洁**，非可见按钮） |
| 模型 | FileWgetProgress 补 key/status 字段（isFinished 判定 Success/Canceled/Error）；旧形状（无 key/status）兼容回落 name |
| 会话 | stopDownload（POST stop 后 WS 推 Canceled）；removeFinishedRecords（对齐 Web onRemove：已完成 key 随手清理，服务端不留下载历史） |
| UI | 进度行：状态徽章（下载中/已完成/已取消/失败）+ 停止滑动操作（进行中行）+ total==0 不定态进度（对齐 Web）；关闭面板时自动清理已完成记录 |

## 2026-09-17 告警启停 + 面板终端会话（v2.3.0 新端点适配收官）

> 全量测试 **294 用例 / 53 套件通过**（+3 回归）。

| 项 | 内容 |
|---|---|
| 告警规则启停 | **新增能力**：规则行滑动「启用/停用」→ 确认弹窗（抓包原文文案）→ `POST /alert/status {id,status}`。注意真实路径为 `/alert/status`（v2.2.5 已有），diff 报告曾误记为新增的 `/alert/config/status`——后者是发送方式启停，两者同形 `{id,status}`，已分别落 case |
| 发送方式启停换轻端点 | `toggleConfig` 从全量 config 回传改为 `POST /alert/config/status {id,status}`（v2.3.0 新增，一参数替代六参数回传） |
| 面板终端会话 | 新页 `PanelTerminalSessionsView`（终端主机页省略菜单「面板会话」入口）：`sessions/search` 列出网页端保留会话（kind 图标 local/ssh/container、attached 在线/已断开徽章）+ 单条滑动关闭（`sessions/close {id}`）+ 全部关闭确认（`sessions/closeAll`）。对应 v2.3.0「SSH 会话保留与断线恢复」的服务端会话治理 |
| 端点 | +5 case（alert/status、alert/config/status、terminal sessions ×3）；词条 +11 |

**v2.3.0 路由 diff 的全部新增端点至此适配完毕**（防火墙全套 / 告警 2 / 文件 2 / 终端会话 3）。
