# 1PanelClient iPad 适配分析与实施计划

> 版本基线：v0.1.10（2026-08-22）· 依据 `Features/`、`PanelShared/`、`PanelWidgets/` 全量源码扫描
>
> 结论先行：**工程层已声明 iPad 支持（可直接安装），但代码层零适配，当前 iPad 上是"拉伸的 iPhone 单列 UI"**。总体改造量中等偏低（详见 §八），推荐"尺寸类双形态导航"路线：compact 维持现状，regular 引入侧栏 + 内容限宽。
>
> **实施状态（2026-08-22）**：路线 B 已落地并通过构建 + 77 项单测 + iPad Pro 13"/iPhone 17 Pro 模拟器验证（侧栏三态切换、横竖屏限宽居中、管理/设置页渲染、sheet 表单、compact 无回归）。各项完成情况见 §五 勾选与"本轮落地说明"。

---

## 〇、本轮落地说明（实现与计划的差异）

| 项 | 落地情况 |
|----|----------|
| 新增基建 | `PanelShared/Shared/Adaptive.swift`：`gridColumns(compact:regular:)` / `contentWidthLimit()` / `formWidthLimit()`；单测 3 项 |
| 主导航 | `MainTabView` regular 分支 NavigationSplitView 侧栏（320pt，selection 复用 `selectedTab`），ZStack 保活与 compact 共享；`atRoot` 隐藏机制仅 compact 生效 |
| 网格列数 | 指标环 4→8、统计卡 2→4、WAF 2→4、网站监控 2→4、服务操作 4→8（均 compact 原值不变） |
| 限宽取值 | 首页 960 / 创建表单与设置 680 / 管理列表 720 / 日志·监控·nginx 配置 860 / 欢迎页 420 / 锁屏键盘 360 |
| 弹层（原阶段3） | 共享组件维持 sheet 形态（计划内备选项）；添加服务器 sheet 已在 iPad 验收（580pt 居中页面式正常）；其余弹层与"sheet→push 联动"留待真机真数据回归 |
| 外设 | Cmd+1/2/3 全局切 Tab（`.commands` + 通知）；终端字号 `@AppStorage` 持久化；Widget 补 `systemLarge`（大字体 + 相对时间脚注）；触控板 hover 未额外定制（系统 List/Button 默认行为已可用） |
| 验证 | iPad Pro 13"：竖屏侧栏+详情限宽、横屏居中留白、设置页 680/管理页 720 生效、sheet 正常、日志无异常；iPhone 17 Pro：compact 无回归；单测 77/77 通过 |
| 待办（下轮） | 终端外接键盘 Ctrl 组合真机实测；AddNodeView→taskProgress 联动真机回归；App Store iPad 截图（13" 必交）；弹层全量走查 |

## 一、结论摘要

| 维度 | 现状 | 结论 |
|------|------|------|
| 工程配置 | `TARGETED_DEVICE_FAMILY = "1,2"`（全部 6 处配置）；iPad 四向旋转；生成式启动屏；无 `UIRequiresFullScreen` | ✅ 已达标，App 可作为原生 iPad 应用安装运行 |
| 代码适配 | `horizontalSizeClass` / `userInterfaceIdiom` / `NavigationSplitView` / `popover` 全库 **0 处** | ❌ 完全按 iPhone 竖屏单列假设编写 |
| 布局风险 | 无大尺寸硬编码（最大固定宽 140pt、高 180pt）；`GeometryReader` 15 处全为图表内比例定位 | ✅ 无溢出类硬伤，问题集中在**结构性全宽拉伸** |
| 导航架构 | 34 处 `NavigationStack`、约 100 处 `navigationDestination`；创建/编辑大流程均为 push 非 sheet | ✅ 现代导航栈，分栏改造成本低 |
| 依赖 | 仅 SwiftTerm（UIKit TerminalView） | ✅ iPad 兼容且为受益项（自动获得更多终端列数） |
| 外设支持 | 无键盘快捷键、无触控板 hover、锁屏键盘为 iPhone 比例 | ⚠️ 打磨项 |
| Widgets | 仅 `systemSmall` / `systemMedium` | ⚠️ 缺 `systemLarge`（iPad/iPhone 通用补齐项） |

**当前 iPad 实际体验（推演）**：底部三个 Tab 按钮横贯 1024pt+ 全屏；首页 4 列指标环 / 2 列统计卡拉成巨大稀疏卡片；表单、日志、TextEditor 全宽铺满；sheet 呈居中页面式但 27 处按 iPhone 刻度写死的 detents 高度显得矮小；锁屏数字键盘 74pt 圆键在全屏画布上比例失调。功能可用、视觉与效率差。

---

## 二、现状盘点

### 2.1 工程配置（无需改动项）

| 配置 | 值 | 说明 |
|------|-----|------|
| `TARGETED_DEVICE_FAMILY` | `"1,2"`（6 处：App/Widgets/Tests × Debug/Release） | iPhone + iPad |
| `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad` | 四个方向 | 满足 App Store 对 iPad 全向的要求 |
| `INFOPLIST_KEY_UILaunchScreen_Generation` | YES | 有启动屏，不会黑屏/错位 |
| `UIRequiresFullScreen` | 未设置 | 支持 Split View 分屏与 Stage Manager ✅ |
| `IPHONEOS_DEPLOYMENT_TARGET` | 26.5 | 可直接使用最新 SwiftUI API（含 iOS 18+ 的 `TabView` sidebar 样式） |

### 2.2 代码层零适配的证据

- 尺寸类/设备分支：`horizontalSizeClass`、`verticalSizeClass`、`userInterfaceIdiom`、`UIDevice` —— **全部 0 处**
- 分栏/弹层：`NavigationSplitView` 0 处、`popover` 0 处、`fullScreenCover` 0 处、`confirmationDialog` 0 处
- 主界面不是 `TabView`：`Main/MainTabView.swift` 用 **ZStack + opacity 切换**保活三个 Tab，自绘 `BottomTabBar` 经 `safeAreaInset(edge:.bottom)` 悬浮（`MainTabView.swift:37-67`、`:75-117`），Tab 按钮内部 `.frame(maxWidth:.infinity)`（`:111`）
- 三个 Tab 各自持有一个 `NavigationStack`（OverviewTab:38 / ManageTab:31 带 path 绑定 / SettingsTab:24）；六个管理子列表（网站/应用/容器/计划任务/证书/应用商店）**有意不含 NavigationStack**，复用 ManageTab 的栈

### 2.3 既有优势（改造量中等偏低的原因）

1. **导航现代化**：无废弃 `NavigationView`；大表单流程（创建网站 248 行、创建数据库 1015 行、创建容器、创建计划任务）全部走 push，iPad 上天然可用
2. **无固定大宽度**：`.frame(width:)` 约 70 处全部 ≤140pt 且多为表单行内控件；`.frame(height:)` 最大 180pt（图表）
3. **图表布局安全**：`GeometryReader` 全部集中在监控图表内做手势定位/气泡测量，均为相对比例计算，随宽度等比缩放不错位
4. **共享弹层组件单点收敛**：删除确认（`TextInputConfirmSheet`）与操作菜单（`ActionBottomSheet`）是 `PanelShared/Shared/CommonComponents.swift` 里的共享组件，各自改一处即覆盖全部调用点
5. **终端受益**：SwiftTerm iOS 版在 `layoutSubviews` 自行按 frame 重算行列（`Terminal/TerminalSurface.swift` 注释明确），iPad 大屏自动获得更多列，无需改动
6. **无全屏覆盖锁屏风险**：应用锁是 `MainTabView().overlay { LockScreenView() }`（`ContentView.swift:22-27`），全屏 overlay 在 iPad/分屏下行为正常

---

## 三、风险清单（分级）

### P0 结构性

| # | 问题 | 位置 | 说明 |
|---|------|------|------|
| R1 | 主导航无侧栏形态 | `Main/MainTabView.swift` | 自定义 BottomTabBar 在 iPad 上三键横贯全屏、触达区巨大；无 sidebar/顶部 Tab 形态，是 iPad 体验的第一瓶颈 |
| R2 | sheet 关闭后向父栈 push 的联动模式 | `Manage/NodeManageView.swift:126-128`（AddNodeView sheet → push taskProgress） | iPad 页面式 sheet + 分栏布局下交互语义需重点验证，全库唯一一处 |

### P1 视觉/可用性

| # | 问题 | 位置 | 说明 |
|---|------|------|------|
| R3 | 固定列数网格 | `Overview/OverviewTab.swift:271`（4 列环）、`:327`（2 列卡）；`Toolbox/WAFMonitorViews.swift:97`（2 列）；`Websites/WebsiteMonitorViews.swift:222,232`（2 列×2）；`PanelShared/Shared/ServiceStatusCard.swift:109`（4 列） | iPad 上每列 ~500pt，卡片巨大稀疏 |
| R4 | 全宽拉伸 | 约 130 处 `.frame(maxWidth:.infinity)`；Form/List 内容无宽度上限；日志逐行 `Text` 横贯全屏（`Websites/WebsiteLogViews.swift:67-81`、`Apps/AppLogView.swift`、`Logs/LogsView.swift:316/525/598`）；24 处 TextEditor 全宽 | 长行日志与表单在大屏可读性差 |
| R5 | 图表超宽扁图 | `Toolbox/MonitorView.swift:866`、`Containers/ContainerMonitorView.swift:263`（高固定 150-180pt） | 视觉可用但建议限宽或双列卡片 |
| R6 | sheet detents 为 iPhone 刻度 | 共 27 处 / 18 文件；无 detents 的大 sheet 约 10+ 个（ServerEditView、AddNodeView[.large]、ScriptLibraryView、FileBrowserView、BackupRecoverSheet、FileCreate/RenameSheet、ChangePasswordSheet 系列等） | iPad 上 sheet 为居中页面式，`.height(200)` 类小高度在 1024pt 画布上矮小孤立；约 18 个 sheet 内容自带 NavigationStack，页面式呈现需逐个验收 |

### P2 打磨项

| # | 问题 | 位置 | 说明 |
|---|------|------|------|
| R7 | 锁屏数字键盘 iPhone 比例 | `Settings/AppLock.swift`（PasscodeKeypad 74pt 圆键，无宽度约束） | 可用但不精致，建议限宽 ~360pt 居中 |
| R8 | 无键盘快捷键 / 触控板支持 | 全库无 `UIKeyCommand` / `onKeyPress` / `onHover` | iPad + 外接键盘是核心使用场景（服务器管理工具），缺失明显 |
| R9 | Widget family 覆盖窄 | `PanelWidgets/`：ServerStatusWidget 仅 small/medium；QuickOpsWidget 仅 medium | 缺 systemLarge；锁屏 accessory 为 iPhone 场景、与 iPad 无关 |
| R10 | 终端快捷键条依赖点按 | `Terminal/TerminalScreen.swift`（设计取舍：SwiftTerm 系统键盘输入无法拦截） | 外接键盘时 Ctrl 组合能否直通取决于 SwiftTerm 内部（支持 pressesEvent），需实测；实测不通再考虑为外接场景补充快捷键 |

---

## 四、适配策略

### 4.1 判定基线：尺寸类而非设备

以 `@Environment(\.horizontalSizeClass)` 为**唯一**分叉点，不用 `userInterfaceIdiom`：

| 场景 | horizontalSizeClass | 行为 |
|------|--------------------|------|
| iPhone 竖屏 | compact | 维持现有 UI（不动） |
| iPad 全屏 / Stage Manager 大窗 | regular | 侧栏 + 限宽内容 |
| iPad Split View 半屏 / 窄窗 | compact | **自动回落到现有 iPhone UI**（无需额外处理，这也是不选 idiom 的原因） |

### 4.2 路线对比

| 路线 | 内容 | 工作量 | 体验 |
|------|------|--------|------|
| A 保守限宽 | 只做 readable width 限宽 + 网格 adaptive，导航不动 | ~3 天 | "能看"，Tab 栏仍是瓶颈 |
| **B 双形态导航（推荐）** | regular → NavigationSplitView 侧栏；内容限宽/自适应网格；sheet 验收 | ~7 天 | iPad HIG 标准 |
| C 全面拥抱 | B + 多栏仪表盘 + 全套键盘快捷键 + 多窗口 | 10+ 天 | 最佳，性价比递减 |

**推荐 B + C 中的键盘快捷键与 Widget 大尺寸两项**（列入阶段 4），合计约 **8–11 个工作日**。

### 4.3 主导航改造设计（R1，关键决策）

保留现有 ZStack 保活三 Tab + `atRoot` 状态机结构，仅在外层按尺寸类分叉：

```
MainTabView
├─ compact：现有结构原样（BottomTabBar + ZStack 切换）
└─ regular：NavigationSplitView(columnVisibility:) 
     ├─ sidebar：List 三项（首页/管理/设置，selection 绑定 selectedTab）
     │           + 管理模块常用入口 section（可选，阶段 1 不做）
     └─ detail：现有 ZStack（三 Tab 内容原样复用）
```

- 侧栏常驻，**不需要** hide-on-push 逻辑（`atRoot` 机制仅在 compact 分支生效）
- `pendingManageItem` 跨 Tab 跳转机制不变
- 备选方案（更彻底、风险更高）：迁移到 iOS 18+ `TabView` + `.tabViewStyle(.sidebarAdaptable)`，免费获得系统顶部 Tab/侧栏切换形态；但需重写自绘 TabBar 与 `atRoot` 隐藏机制，且失去对栏行为的控制。**不推荐本期做**，可作为未来重构方向

### 4.4 内容自适应工具（一次性基建）

新建 `PanelShared/Shared/Adaptive.swift`：

1. `contentWidthLimit(max: 720)` —— Form/长表单/日志容器在 regular 下限宽居中（内部 `frame(maxWidth:)` + `frame(maxWidth:.infinity)` 对齐组合），compact 下直通
2. `adaptiveColumns(compact:regular:)` —— 网格列数帮助函数，替换 6 处固定列
3. `regularOnly<T>(_ value: T)` —— 环境注入 sizeClass 的便捷读取（ViewModifier 形式）

网格改造原则：优先 `[GridItem(.adaptive(minimum:))]`（卡片自适应增列）；圆环行（OverviewTab 4 列）这种"每行固定 4 项"的语义布局改按 sizeClass 切列数（regular 竖排两行×2 或保持一行但限宽容器）。

### 4.5 弹层改造原则（R6）

- **ActionBottomSheet / TextInputConfirmSheet**：仅改共享组件一处 —— regular 下考虑改 `popover`（iPad 操作菜单的 HIG 形态）或维持 sheet 但确保 detents 用 `.medium/.large` 相对值而非 `.height(200)` 绝对值
- 大表单 sheet（ServerEditView / AddNodeView / ScriptLibraryView / FileBrowserView）：iPad 页面式 sheet 本身居中限宽，先验收再决定是否需要额外处理；sheet 内嵌 NavigationStack 的迷你表单（SSHFieldSheet 等约 18 个）逐个过一遍截图
- R2（AddNodeView → push taskProgress 联动）：单点，真机/模拟器验证后如异常改为 sheet 内自含进度展示

---

## 五、分阶段实施计划

### 阶段 0：基线与基建（0.5 天）✅

- [x] iPad 模拟器矩阵跑通现状，截图存档基线（本轮以 iPad Pro 13" 为准）
- [x] 新建 `Adaptive.swift` 三工具 + 对应单测（`AdaptiveLayoutTests`，3 项通过）
- [x] 确认分屏（1/2、1/3）下 compact 回落无异常（compact 分支代码零改动，iPhone 模拟器回归通过；真机分屏拖拽留待下轮）

### 阶段 1：主导航双形态（2 天）✅

- [x] `MainTabView` 增加 regular 分支：NavigationSplitView + sidebar List（selection 绑定现有 `selectedTab`）
- [x] `atRoot` 隐藏机制仅在 compact 分支生效；侧栏常驻
- [x] `WelcomeView`（首启欢迎页）regular 下限宽居中（420）；`ServerEditView` sheet 验收通过
- [x] 验收：横竖屏旋转通过；Split View 拖拽 / Stage Manager 留待下轮
- **里程碑 M1**：✅ 已达成（模拟器验证侧栏三态切换正常）

### 阶段 2：内容与网格（3 天）✅

- [x] 6 处固定列网格改 sizeClass 切列（环 4→8、统计卡 2→4、WAF 2→4、网站监控 2→4、服务操作 4→8）
- [x] Form 类长表单套 `formWidthLimit`：创建网站/数据库（含创建用户）/容器/计划任务、服务器编辑、节点编辑、设置页 680、管理页 720
- [x] 日志视图限宽 860：网站日志 ×2、应用日志、系统/网站日志共用 `LogLinesView`
- [x] nginx 配置编辑器与 24 处 TextEditor 随容器限宽（配置页 860；表单内编辑器随 formWidthLimit）
- [x] 监控图表容器限宽 860（MonitorView）；首页概览整页限宽 960 + 网格增列
- [x] 管理页 20 入口列表限宽 720（双列网格方案未采用，保持 Form 分组语义）
- **里程碑 M2**：✅ 已达成（横屏限宽居中留白验证通过）

### 阶段 3：弹层体系（1.5 天）◐ 部分完成

- [x] 添加服务器 sheet（ServerEditView）iPad 验收通过（580pt 居中页面式，键盘弹出正常）
- [ ] `ActionBottomSheet` / `TextInputConfirmSheet` 共享组件维持 sheet 形态（计划内选项）；popover 化与宽度收紧视真机观感决定
- [ ] 大 sheet 逐个验收：AddNodeView（含 R2 sheet→push 联动）、ScriptLibraryView、FileBrowserView、BackupRecoverSheet、数据库密码系列 —— 需真机真数据，下轮回归
- [ ] `.height(200)` 类绝对值 detents 复查（SSHView:343 等 7 处迷你表单）
- **里程碑 M3**：待真机数据回归后关闭

### 阶段 4：外设与打磨（2 天）◐ 部分完成

- [x] 全局键盘快捷键：Cmd+1/2/3 切 Tab（`.commands` 发通知 + MainTabView 监听）
- [ ] 终端外接键盘实测（SwiftTerm pressesEvent 是否消费 Ctrl 组合）——模拟器无法模拟硬件键盘，留待真机
- [x] 触控板 hover：未额外定制（系统 List/Button 指针高亮默认可用，观感问题下轮再加 `.hoverEffect`）
- [x] `PasscodeKeypad` 限宽 360 居中
- [x] Widgets 补 `systemLarge`（ServerStatusWidget：大字体 + 相对更新时间脚注）
- [x] 终端字号持久化（`@AppStorage("terminal.fontSize")`）

### 阶段 5：回归与发布（1 天）◐ 持续

- [x] 构建通过（iPad/iPhone 双目的地）；单测 77/77 通过（含新增 3 项）
- [x] iPad Pro 13" 竖屏 + 横屏截图验证（侧栏、限宽、管理/设置/概览渲染）
- [x] iPhone 17 Pro compact 回归（欢迎页布局正常）
- [x] 应用日志检查（无崩溃/异常，仅系统级良性消息）
- [ ] 全矩阵回归（iPad mini/Air/Pro 11、分屏 1/2 与 1/3、Stage Manager、外接键盘+触控板、深色、双语）——下轮
- [ ] 重点回归文件（FilesView、BackupListView、NodeDetailView、DatabasesView）——需真数据
- [ ] 应用锁 iPad 无 FaceID 机型回落验证
- [ ] App Store：iPad 截图集（13" 必交）、文案标注 iPad 支持

---

## 六、逐文件改造清单（按阶段索引）

| 文件（相对 `1PanelClient/`） | 问题 | 改法 | 阶段 |
|------|------|------|------|
| `1PanelClient/Features/Main/MainTabView.swift` | R1 自定义 Tab 栏 | regular 分支 NavigationSplitView 侧栏 | 1 |
| `1PanelClient/Features/Main/MainTabView.swift:126`（WelcomeView） | 全宽拉伸 | 限宽居中 | 1 |
| `PanelShared/Shared/Adaptive.swift`（新建） | — | 三个自适应工具 | 0 |
| `1PanelClient/Features/Overview/OverviewTab.swift:271,327` | 固定 4/2 列 | adaptive/切列 | 2 |
| `1PanelClient/Features/Toolbox/WAFMonitorViews.swift:97` | 固定 2 列 | adaptive | 2 |
| `1PanelClient/Features/Websites/WebsiteMonitorViews.swift:222,232` | 固定 2 列×2 | adaptive | 2 |
| `PanelShared/Shared/ServiceStatusCard.swift:109` | 固定 4 列 | 切列 | 2 |
| `1PanelClient/Features/Websites/CreateWebsiteView.swift` 等 4 个创建流程 | 表单全宽 | contentWidthLimit | 2 |
| `1PanelClient/Features/Websites/WebsiteLogViews.swift:67` / `Apps/AppLogView.swift` / `Logs/LogsView.swift:316,525,598` | 日志行全屏宽 | 容器限宽 | 2 |
| `1PanelClient/Features/Websites/WebsiteNginxViews.swift:64`（minHeight 480 TextEditor）等 24 处 TextEditor | 编辑区全宽 | 限宽 | 2 |
| `1PanelClient/Features/Toolbox/MonitorView.swift:866` / `Containers/ContainerMonitorView.swift:263` | 图表超宽 | 限宽/双列卡 | 2 |
| `1PanelClient/Features/Manage/ManageTab.swift`（20 入口列表） | 全宽 | 限宽/双列 | 2 |
| `PanelShared/Shared/CommonComponents.swift`（ActionBottomSheet / TextInputConfirmSheet） | R6 弹层形态 | regular popover/相对 detents | 3 |
| `1PanelClient/Features/Manage/NodeManageView.swift:126-128` | R2 sheet→push 联动 | 验证，异常则自含进度 | 3 |
| `1PanelClient/Features/Server/ServersView.swift:102` 等全部 detents 调用点 | 绝对高度 | 复查替换 | 3 |
| `1PanelClient/Features/Settings/AppLock.swift` | R7 键盘比例 | 限宽 360 | 4 |
| `PanelWidgets/ServerStatusWidget.swift` | R9 | 补 systemLarge | 4 |
| `1PanelClient/_PanelClientApp.swift` | 无快捷键 | `.commands` 全局快捷键 | 4 |

---

## 七、测试清单（阶段 5 执行）

**设备矩阵**：iPad mini（compact 窗口最小）、iPad Air 11"、iPad Pro 13"；每台 × 竖屏/横屏/左右分屏 1/2 / 1/3 / Stage Manager 任意缩放

**功能走查**（每项在 regular + compact 各过一遍）：

1. 首页：指标环/统计卡布局、实时监控图表、多机总览卡、切服务器
2. 管理：20 入口导航、六列表页搜索/筛选、创建网站/数据库/容器/计划任务全流程、AddNodeView → taskProgress 联动
3. 文件管理器：上传下载进度 sheet、重命名/新建 sheet、长列表滚动
4. 终端：连接主机/容器/Redis/数据库终端、快捷键条、字号缩放、**外接键盘 Ctrl 组合实测**、旋转屏后行列重算
5. WAF/防火墙/Fail2ban：三段切换横条、各操作 sheet
6. 备份/证书/告警：各确认 sheet 与 alert 叠加场景
7. 应用锁：密码键盘布局、iPad 无 FaceID 机型回落、退后台重锁
8. Widgets：iPad 主屏 medium/large 尺寸刷新
9. 深色模式 + 中英双语 × 上述抽查
10. 性能：iPad Pro 上监控图表 60fps、列表快速滚动无掉帧

---

## 八、工作量与里程碑

| 阶段 | 内容 | 估时 | 里程碑 |
|------|------|------|--------|
| 0 | 基线截图 + Adaptive 工具 | 0.5 天 | — |
| 1 | 主导航双形态 | 2 天 | **M1** iPad 可用性质变，可内测 |
| 2 | 内容与网格 | 3 天 | **M2** 视觉达标 |
| 3 | 弹层体系 | 1.5 天 | **M3** 交互达标 |
| 4 | 外设与打磨 | 2 天 | — |
| 5 | 回归与发布 | 1 天 | 发布 |
| **合计** | | **~10 个工作日** | |

阶段 1–3 为核心（6.5 天）即可达到"iPad 正式支持"水准；阶段 4–5 决定口碑。

## 九、不在本期范围（明确排除）

- Apple Pencil 手写/标注
- iPad 多窗口（`WindowGroup` 多开、一窗一服务器）—— 可作为 v2 亮点，依赖当前导航改造完成
- visionOS / Mac Catalyst
- 锁屏 accessory Widgets（iPhone 场景）
