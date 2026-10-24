# CI 与测试踩坑

本地全绿 ≠ CI 绿的已知差异与定位方法（2026-10-24 起实证，随踩随补）。

## CI 环境

- runner：`macos-26` 镜像，**Xcode 26.6**（`DEVELOPER_DIR` 指定）+ iOS 26.5 模拟器——
  本地开发用 Xcode 27.x，CI 承担「低一档工具链仍可编译」的兼容性回归；
- 两个 required check：`Build & Test（Xcode 26.6 / iOS 26.5 模拟器）`、
  `L10n key 同步检查`（分支保护要求全绿才能进 main，对 admin 同样生效）。

## 一、类型检查超时（Xcode 26.6）

**症状**：本地构建/测试全绿，CI 红在
`The compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions`。
gh run 文本日志被 xcbeautify 吞掉了 file:line，只剩一行 error，无法直接定位。

**定位**（失败时 workflow 自动上传 `test-results.xcresult` artifact）：

```shell
gh run download <run_id> -R xy2026yi/1PanelClient -n test-results.xcresult -D /tmp/ci
cd /tmp/ci && xcrun xcresulttool get --legacy --format json --path . > /tmp/xcr.json
# 解析 issues.errorSummaries[].documentLocationInCreatingWorkspace.url
# → 携 StartingLineNumber 的精确文件行号（python 正则提取）
```

**已实证的超时模式与修法**（2026-10-24 两轮，AIVllmMonitorView + KVM 各视图）：

| 模式 | 修法 |
|---|---|
| `.task { while !Task.isCancelled { Task.sleep(for: .seconds(5)) … } }` 内联轮询循环 | 循环提取为独立方法（如 `pollLoop()`），循环变量加显式类型标注 |
| `body` 修饰符链过长（10+ 级） | 拆多个计算属性分段检查（rootContent / statefulContent；toolbar 用 `@ToolbarContentBuilder`） |
| 手势长链（DragGesture + 多个 simultaneousGesture + tap + onKeyPress） | 整段提取为独立方法（如 `inputLayer(in:)`） |
| `foregroundStyle(cond ? AnyShapeStyle(A) : AnyShapeStyle(B))` 三元包装 | 改直通类型（`Color.secondary` 本身就是 Color，无需 AnyShapeStyle） |
| 复杂 if/else 分支内重复表达式 | 先 let 绑定再使用（同时消强解包） |

**预防**：Swift 编译按文件批并行，错误在首个失败批中止——失败批之后的文件
（如整目录新模块）**从未被旧工具链编译过**，坑会一轮轮往外冒（当天 1m38s →
3m15s → 11m12s 三轮递进）。新增长修饰符链的 View 主动按上表拆，别等 CI 试错。

## 二、测试断言必须 locale 无关

CI 模拟器默认**英文 locale**：`L10n.t("内存分配超过宿主机总量")` 返回英文文案，
断言里硬编码中文子串必然落空——而 "CPU" 这类碰巧双语命中的断言会掩盖问题，
呈现 516/517 通过的假象（2026-10-24 实证）。

```swift
// ✓ locale 无关：断言与生产同源解析、精确比较
#expect(risks.contains { $0.message == L10n.t("内存分配超过宿主机总量") })
#expect(risks.contains { $0.message == L10n.f("CPU 分配（%ld 核）超过宿主机总量（%ld 核）", 3, 2) })

// ✗ CI 必挂：硬编码子串
#expect(risks.contains { $0.message.contains("内存") })
```

非文案断言（数值、结构、字节序）不受影响；只断言语义时优先比数值而非文案。
