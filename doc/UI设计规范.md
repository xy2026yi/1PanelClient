# UI 设计规范

> 阶段 0 产出，依据 `doc/UI一致化实施计划.md`。后续所有 UI 改动以此为依据；规范本身可通过 PR review 修订，修订后同步更新本文件版本号。
> 2026-09-16 从 `archive/doc/` 移回 `doc/`（DesignTokens.swift / Haptic.swift 等源码一直引用本路径；archive/ 为 gitignore 的本地资料目录）。

版本：v1.1（2026-09-16）——§一 补删除分层判定细则与批量强度规则（依据 2026-09-16 四维审查 P1 结论）；其余与 v1.0 一致。

---

## 一、删除风险分级表（弹窗/确认方式的选择依据）

| 级别 | 判定标准 | 确认方式 | 组件 |
|------|---------|---------|------|
| R1 不可恢复 / 连带删除 | 见下方「R1 判定细则」 | 必须输入资源名称（节点用节点名，不用「确认」等泛词）；附加选项通过 `options` 传入 | `TextInputConfirmSheet` |
| R2 一般删除 | 删除单一资源，可通过重建恢复（证书、镜像、主机、备份、单条规则、会话记录等） | 原生 `.alert`，标题「删除XX」，正文说明后果；按钮「删除」+ `role: .destructive`、「取消」+ `role: .cancel`（取消在前） | 原生 alert |
| R3 低风险操作 | 服务启停、开关切换、同步、重载等可逆操作 | 原生 `.alert`（影响面大的启停保留确认），微小操作可直接执行 | 原生 alert |

**R1 判定细则**（满足任一即 R1，须输入名称确认）：

1. 操作不可撤销**且**资源承载用户数据（数据库、数据库用户、计划任务及其执行历史）；
2. 会连带删除其他资源或影响数据盘（网站、应用卸载含删库/删备份选项、节点含删数据选项、容器编排所辖服务）；
3. 影响服务可用性（面板/系统/节点重启、保存配置需重启的操作）；
4. 资源本身是生产流量入口（网站域名、AI 智能体、SSH 密钥、安全类规则如 Clam）。

容器（单删）按 R1 细则第 2/4 条常见命中（挂载卷/业务进程）——**从 v1.1 起列为 R1 对齐项**（见下表）。

补充规则：

- **同一实体在列表页与详情页（含批量入口）必须同强度**：不允许详情页要求输入名称、列表页一键删除（2026-09-16 已修复网站列表长按删除的双强度问题，统一走 `WebsiteDeleteConfirmSheet`）。
- **批量操作的确认强度不得低于单删**：批量删除 R1 实体（网站、文件永久删除等）必须同样输入确认文本或逐项列出将删除的对象；批量删除 R2 实体可用 alert 但正文须含数量与「不可回滚」提示。
- `confirmationDialog` 全站不使用（存量「移除服务器」「HTTP 明文连接警告」已于 2026-08-22 改为居中 alert）。
- alert 结构：标题用短词（「删除证书」「提示」），长文案放 message；禁止把错误信息当标题。
- 状态提示 alert 确认按钮统一「好的」+ `role: .cancel`。

**存量偏差对齐清单**（2026-09-16 审查发现，P2 排期，按本表逐项对齐）：

| 现状 | 位置 | 目标级别 |
|---|---|---|
| 容器/镜像/网络/卷一键删 | ContainerDetailView.swift:179 等 | 容器→R1；镜像/网络/卷维持 R2 可接受，批量时按批量规则 |
| SSL 证书一键删（SSH 密钥已输入名） | CertificatesTab.swift:145/356 | 维持 R2 可接受（可重传证书），但补「不可撤销」措辞 |
| FTP/AI/Acme/DNS/备份账号一键删 | FtpView.swift:321 等 | 维持 R2 可接受（账号可重建） |
| AI 频道/角色/会话一键删 | AIAgentChannelViews.swift:298 等 | 频道含凭证配置→升 R1 待议；会话维持 R2 |
| WAF 规则一键删（Clam 已输入名） | WAFIPRulesView.swift:130 等 | 维持 R2 可接受（规则可重建），与 Clam 的差异记录在案 |
| 快照一键删 | SnapshotViews.swift:92 | 维持 R2（快照可重建） |
| 批量删网站/批量永久删文件一键 | WebsitesTab.swift:166、FilesView.swift:355 | **升强度**：批量网站→输入确认；批量文件→正文列数量+「永久删除不进回收站」（已有）保持 alert 可接受 |

## 二、页面进出场判定表

| 场景 | 呈现方式 | 细节 |
|------|---------|------|
| 创建 / 编辑大表单（>3 个字段） | push（`navigationDestination`） | toolbar「取消/保存」或「创建」 |
| 选择器、改单值、R1 确认、底部操作菜单 | sheet | `.presentationDetents([.medium])` + `.presentationDragIndicator(.visible)` |
| 全屏沉浸场景（终端） | push | 维持现状 |
| sheet 内表单 toolbar | `cancellationAction`（取消）+ `confirmationAction`（保存/创建/删除） | 禁用 `topBarLeading/topBarTrailing`、`.destructiveAction` 摆确认/取消按钮 |

底部操作弹层两种形态的判据（v1.1 补）：

- **纯菜单**（对某对象/区域列一组操作，无需展示对象信息）：`ActionBottomSheet`（CommonComponents）。全站默认；24+ 调用点。
- **实体操作面板**（信息头展示实体摘要——名称/地址/规则要点 + 分组操作行，操作行可带副标题）：`FirewallActionSheet` / `ServerActionsSheet` 的解剖结构（NavigationStack + List 信息头 Section + 操作 Section + bottomSheetDetents([.medium])）。新增实体级操作场景复用该结构，不与纯菜单混用。

按钮文案（表单确认位仅 3 种 + 流程特例）：

- 新建 →「创建」；修改现有 →「保存」；删除 →「删除」（destructive）
- 多步流程特例允许：「下一步」「立即重启」等动词性文案
- 提交中状态：「保存中…」（统一，不用「提交中…」）；按钮内用 ProgressView 替换文字时不带省略号

新代码导航 API 优先级：列表行 → 详情用 `navigationDestination(for:)` 值路由；状态驱动的二级跳转用 `navigationDestination(isPresented:)`。存量 `NavigationLink { }` 直接推不做强制迁移。

## 三、语义色映射表（DesignTokens.swift）

| Token | 系统色 | 语义 |
|-------|--------|------|
| `Color.statusRunning` | `.green` | 运行中 / 健康 / 成功 |
| `Color.statusStopped` | `.gray` | 正常停止（不是错误） |
| `Color.statusError` | `.red` | 故障 / 错误 / 删除 |
| `Color.semanticWarning` | `.orange` | 警告三角 / 重试横幅 / 到期预警 |
| `Color.semanticSuccess` | `.green` | 成功提示 |

规则：

- 「停止」一律灰（正常状态），只有明确故障/错误才用红；红色留给 error 与 destructive。
- 警告三角统一 `exclamationmark.triangle.fill` + `semanticWarning`（橙）。
- 圆角三档：`Radius.small` 8（小元素/二级图标块）、`Radius.medium` 12（IconBadge 默认）、`Radius.large` 16（卡片）。
- 间距四档：4 / 8 / 12 / 16；新增代码禁止 5、6、7、14、15、2.5 等游离值。
- 图标语义：删除=`trash`、编辑=`pencil`、复制=`doc.on.doc`、刷新数据=`arrow.clockwise`、重启/同步=`arrow.triangle.2.circlepath`、成功=`checkmark.circle.fill`、证书有效=`checkmark.seal.fill`（统一 fill 变体）、加载失败=`wifi.exclamationmark`。
- 数据类文本（IP、端口、密码、ID、域名、路径）用 `.system(.caption/.subheadline, design: .monospaced)`（真等宽）；`.monospaced()` 仅用于纯数字场景（百分比、计数）。
- 模块入口图标与颜色以 `ManageTab.swift` 的定义为唯一基准（见阶段 5 PR-5a 对照表）。

## 四、动画时长表

| 场景 | 时长 / 曲线 |
|------|------------|
| 折叠展开（详情抽屉、监控卡） | 0.25s easeInOut |
| Toast 出入 | 0.3s easeInOut |
| 按压反馈（PressableCardStyle） | 0.12s easeOut |
| Tab 切换 / EllipsisMenu | 维持现状（0.15s / 0.18+0.12s） |
| 列表刷新 / 筛选 | `withAnimation` 必须带明确时长，禁止无参 |

## 五、加载 / 空 / 错误状态

- 加载：统一 `LoadingStateView(text:)`（居中 + 「加载中…」，特例：加载日志…、正在连接…）；行内小组件 `scaleEffect(0.7)` 统一。
- 空：统一 `ContentUnavailableView`；禁止新写 `Text("暂无数据")` 类自绘空态。
- 错误：统一 `ContentUnavailableView + Label("加载失败", "wifi.exclamationmark") + 重试按钮`；`ErrorBanner` 仅用于首页概览的非全屏降级场景，不再扩展使用。
- 主列表与详情页必须支持 `refreshable`。
- 搜索：列表页统一 `searchIconMode`，不用 `.searchable`。

## 六、触觉反馈（阶段 6 落地后追加）

- 危险操作确认执行 → `UINotificationFeedbackGenerator(.warning)`
- 操作成功 → `UINotificationFeedbackGenerator(.success)`
- Tab 切换 / 选择器 → `UISelectionFeedbackGenerator`

## 七、图表

- 统计图表主体已全部使用 Swift Charts（MonitorView / WebsiteMonitorViews / ContainerMonitorView / WAFMonitorViews）；`chartOverlay` 内的手势采样位吸附、数值气泡、自绘时间轴为官方推荐的交互扩展模式与硬需求（系统轴不支持段位居中），**不属于自绘图表，不迁移**。详见 `doc/图表迁移评估.md`。
- 新增统计图表一律使用 Swift Charts；Gauge 类控件（RingStatView 进度环、微型指标条）保持 `Circle().trim` / Capsule 自绘。
