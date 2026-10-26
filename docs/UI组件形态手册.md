# UI 组件形态手册

> 活文档：表单形态（形态 1–10）、包边组件（Outlined 系列）、向导体系、分页加载的**定义、选用判据与 API 速查**。
> 与 `docs/UI设计规范.md` 的分工：规范 = 必须遵守的规则与判定表（删分级/进出场/色板/时长/状态）；本手册 = 组件与形态目录（是什么、何时用、怎么用）。
> 形态编号源自 2026-09 描边化改造（推进存档见 `docs/references/outlined-form-adoption-assessment-2026-09.md`），编号保持稳定，新增形态续编（10 之后）。

版本：v1.0（2026-10-25）

---

## 一、表单控件形态（1–10）

创建/编辑表单的字段控件从以下形态中选型；**禁止在新代码里引入第 11 种字段样式**（确需新形态先在本手册补条目再落地）。

### 形态 1 — 文本输入（描边）

- **组件**：`OutlinedTextField`（密码场景用变体 `OutlinedPasswordField`，眼睛切换明文/密文）
- **何时用**：单行文本、数字（配 `keyboardType`）、路径/域名等机器值输入
- **关键参数**：
  - `prompt`：空值时框内右侧占位（如「可选」「默认 8080」）；`hint`：框下方常驻提示（格式示例/说明），两者不同位
  - `machineValue`（默认 true）：禁自动大写与纠错；路径类字段配 `browseAction` 内嵌目录浏览按钮
- **示例**：

```swift
OutlinedTextField(label: L10n.t("名称"), text: $name)
OutlinedTextField(label: L10n.t("外部端口"), prompt: "8080", text: $portText,
                  keyboardType: .numberPad)
OutlinedTextField(label: L10n.t("运行目录"), prompt: "/", text: $codeDir,
                  hint: L10n.t("项目代码所在的服务器目录"),
                  browseAction: { showDirPicker = true })
```

- **不用**：多行内容（形态 7.1）、配置全文（形态 7）、只读展示（用 `LabeledContent` 或形态 1 只读 + 小锁变体——`OutlinedShape` 传 `isFocused: false` + 锁图标，见快照恢复页）。

### 形态 2 — 菜单选择（描边）

- **组件**：`OutlinedPicker`
- **何时用**：互斥选项中选择一个；值/显示名需分离的场景
- **关键参数**：`options`（**机器值**数组）、`optionLabels`（值→显示名）、`disabledOptions`；String-rawValue 枚举可用枚举便利 init（传 `display:` 闭包）
- **示例**：

```swift
// 值/显示分离（提交机器值，展示本地化名）
OutlinedPicker(label: L10n.t("镜像源"), options: npmSourceValues,
               selection: $source, optionLabels: npmSourceLabels)
// 枚举便利 init
OutlinedPicker(label: L10n.t("类型"), options: RuntimeType.allCases,
               selection: $type) { $0.displayName }
```

- **注意**：`selection` 绑定的是**机器值**不是显示名；空数据源时显示「没有找到XX」并参与页门控（见向导 §三 pageReady）。

### 形态 3 — segmented 选择（表单字段级，降级为菜单）

- **结论**：**表单字段不做描边化分段控件**——一律降级为形态 2 `OutlinedPicker`；选中特定选项时下方条件展示关联输入区（首个场景：MySQL 权限「所有人/指定IP」→ 指定 IP 时出现 7.1 输入）。
- **保留原生 segmented 的边界**（页面级控件，不是表单字段）：页面板块切换、列表筛选分段、图表时间范围（监控 1h/6h/24h/7 天、防火墙规则/转发/Docker、日志类型等）。**判据：切换的是「页面内容」而非「提交的表单值」→ segmented；反之 → 形态 2。**

### 形态 4 — Toggle 开关（系统样式）

- 与描边框混排用系统 `Toggle` 行，不做描边化（应用安装高级页实测确认）。

### 形态 5 — 数字 + 单位组合行

- **组件**：`OutlinedUnitField`
- **何时用**：带固定单位的数值（核 / MB / 秒）；单位可切换时用「数值框 + 形态 2 单位菜单」拆分（第九批约定：Clam 超时、监控采集间隔、内存六处 KB/MB/GB）
- **关键参数**：`unit`（框右侧常驻单位）、`range`（失焦钳制区间）、`allowsDecimal`（CPU 0.5 核）、`onCommit`（**numberPad 无回车键，保存时机靠失焦**）、`hint`
- **行为要点**：输入中放宽（可删空/超范围不回弹），**失焦归位钳制**；编辑回填统一「整除取大单位」规则。
- **示例**：

```swift
OutlinedUnitField(label: L10n.t("内存限制"), unit: "MB", prompt: "128",
                  text: $memory, range: 0...65536) { await save() }
```

### 形态 6 — 日期/时段/时间

- **组件**：`OutlinedTimeField`：描边框显示 HH:mm（**不可键入**）+ 时钟图标，点击弹底部轮盘选择、选定回填。

### 形态 7 — 多行大文本（配置全文）

- **组件**：`CodeEditorArea`（代码编辑器场景）——nginx/sshd/clamd/supervisord 等约 15 个源文件编辑页。
- **不描边化**：大文本编辑走全屏编辑器（`FullscreenTextEditorSheet`）或只读滚动 + 编辑切换；**不要**用 7.1 装配置全文。

### 形态 7.1 — 多行描边输入（短多行）

- **组件**：`OutlinedMultiLineField`
- **何时用**：表单级多行字段——一行一条的列表型值（IP 白名单、排除规则、URL 列表、Headers 模版），或 2–5 行的说明/命令
- **关键参数**：`lines`（默认行高，超出自动增高）、`fixedLines`（固定高框内滚动）、`zoomable`（放大按钮进全屏编辑，实时绑定）、`monospaced`（脚本/密钥类 true）、`prompt`（聚焦空值时框内格式提示）
- **示例**：

```swift
OutlinedMultiLineField(label: L10n.t("IP"), prompt: "一行一个 IP",
                       lines: 5, text: $ips)
```

- **约定**：一行一条的值在提交时按行拆分/拼接；键值类（环境变量）特殊格式（如 Supervisor 引号感知拆合）须写注释说明服务端口径。

### 形态 8 — 动态行编辑器（入口行 → 行编辑页）

- **结构**：**不在行内堆多个描边框**。列表页用「入口行（`未设置` / `N 条` 摘要）→ 子编辑页」；子页每行一个 Section、字段用描边组件。
- **统一样式 A**（第九批起全站统一）：Section 节头「`端口-N` / `挂载-N` / `IP-N` / `模型-N`」+ 节尾 trash 删除按钮（**不用**行内 minus.circle.fill）；底部「添加」行。
- **校验**：提交前逐行校验（端口 1–65535、必填非空，报错带行号），全空行静默丢弃（参照 `RuntimeAdvancedArrays.validationError`）。
- **示例**：容器端口/挂载、MCP 挂载、模型池、计划任务执行周期（周期编辑页）。

### 形态 9 — 九宫格/树/角色多选

- **不适用描边化**：文件权限树、快照包含项、Mongo 角色等保持现有专用控件。

### 形态 10 — 验证/测试按钮内嵌

- **保持系统样式**：服务器编辑「测试连接」等按钮 + 结果行不做描边化（用户确认）。

---

## 二、包边组件底层与通用守则

- **底层壳** `OutlinedShape`：描边框 + 浮动标签（空态标签贴框内、聚焦/有值标签横跨描边线）。一般**不直接使用**——直接用七个封装件；形态 1 只读 + 小锁等特殊变体除外。
- **硬性技术守则**（组件结构不可局部改动，改动需回归以下各项）：
  1. 标签跨线依赖「13pt 顶部缓冲 + 框内偏移」，Menu 裁剪已按此解决；
  2. 动态字体：偏移量经 `ScaledMetric` 联动，禁止硬编码字号/偏移；
  3. 标签背景截线在 sheet/白底/深色下靠环境背景取色，勿写死背景色；
  4. 无障碍：空/浮两份标签 opacity 切换须配 accessibility 处理，避免 VoiceOver 重复朗读；
  5. 行高约 65pt（系统行 ~44pt），长表单需配合分页向导对冲（§三）。
- **组件文件**：`PanelShared/Shared/OutlinedField.swift`；原型调试页 `DebugInstallFormView`（Debug 菜单）。

## 三、分页向导体系

- **组件**（`PanelShared/Shared/WizardScaffold.swift`）：
  - `WizardStepsBar`：顶部步骤条（页名分段 + 当前位）
  - `WizardBottomBar`：`safeAreaInset(edge: .bottom)` 底部导航（返回/下一步/末页主操作「创建」，busy 状态统一禁用）
  - `WizardDiscardGuard`：中途返回确认（push 翻页用；sheet 翻页时配「翻页后禁下拉」）
- **适用判据**：**多段新建流**（安装应用、创建容器/网站/计划任务/MCP/vLLM/智能体、申请证书、备份账号、添加节点、创建快照等）。**不适合**：仅编辑型（78 个，改一处不该翻页）、微表单（1–2 字段）、操作类（压缩/移动/批量）。
- **页面门控 `pageReady`**：某页依赖的数据源为空时（无可用许可证/无 DNS 账户），该页形态 2 显示「没有找到XX」并**禁用下一步**。
- **入口方式**：向导页一律 **push**（不用 sheet），提交后进度页由表单内 push、完成分步收栈（进度页自 dismiss → 稍后收表单 → 外层收列表页，避免同帧多层 isPresented 拆除警告）。
- **每页校验**：`pageInvalid` 按当前页字段卡「下一步/创建」，后续页字段不卡当前页；末页按完整提交校验。

## 四、列表分页加载（全站约定）

- **无限滚动，无页码控件**：列表末行 `onAppear` 触发 `loadMore`；服务端分页参数 `page`/`pageSize`（列表页常用 20，导出/全选场景临时放大到 500 补齐剩余分页）。
- **loadMore 守卫**（防重复/防越界）：

```swift
func loadMore() async {
    guard runtimes.count < total, !isLoading else { return }
    // generation 代号防乱序；成功按 id 去重合并；失败 page 回退 + toast
}
```

- **错误/加载态守卫**（2026-10-25 全站对齐）：错误分支与 loading 分支必须带数据非空守卫——`else if let err = errorMessage, xxx.isEmpty`，已有数据时刷新失败保持旧数据展示（VM 层可降级 toast），不得整页替换。
- **VM 载具**：跨入口共享的列表用 `PageVMStore.shared.vm(key:)` 缓存实例（返回列表页不重拉）。
- **过度态轮询**：存在 Creating/Building 等过渡态的列表用 `adaptivePolling(interval: 5, isActive:)` 收敛，轮询失败按上一条守卫降级。

## 五、底部操作两层（引用规范 §二）

- **纯菜单**（列一组操作，无需实体信息头）：`ActionBottomSheet`——**detents 与拖动指示器由组件内统一挂**（按条目数自适应高），调用点只传 `title/items/onDismiss`，勿再挂 detents。
- **实体操作面板**（信息头展示实体摘要 + 分组操作行）：参照 `FirewallActionSheet` / `ServerActionsSheet` 解剖结构，组件内自挂 `bottomSheetDetents([.medium, .large])`。
- 判据与删除强度分级见 `docs/UI设计规范.md` §一/§二。

---

## 修订记录

| 版本 | 日期 | 内容 |
|---|---|---|
| v1.0 | 2026-10-25 | 从规范与 2026-09 推进存档中析出：形态 1–10 定义与判据、包边组件 API、向导体系、分页加载约定、底部操作两层 |
