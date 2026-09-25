# ADR-0002：接入 MetricKit 做本地诊断（审计项 D6）

- 日期：2026-09-06
- 状态：已接受（随 P2 实施）
- 关联：`doc/references/project-audit-report-2026-09.md` §5-D6、§7-P2；`doc/references/audit-fix-log-2026-09.md`

## 背景

审计报告 D6 指出：项目当前为纯零遥测立场（无任何崩溃/性能上报渠道），
真机侧载使用中出现的崩溃与卡顿完全不可观测，问题定位只能靠用户口述。
报告建议接入 MetricKit（MXMetricManager）——Apple 原生、无第三方 SDK、
数据先到系统再投递给 App，不引入隐私申报负担；或维持零观测并在报告记录豁免理由。

## 决策

**接入 MetricKit，但维持「零上报」立场：数据仅本地持久化，绝不联网。**

1. `PanelShared/Core/Metrics/MetricKitSubscriber.swift`：订阅
   `MXMetricManager.shared` 的 metric/diagnostic payload（每日聚合指标 + 崩溃/卡顿诊断），
   以系统生成的 JSON 写入 `Application Support/Metrics/`，按文件日期保留最近 30 天，过期自动清理。
2. 设置 → 关于 → 「诊断数据（本地）」入口：列出已存 payload 文件，
   用户可通过系统分享面板手动导出 `.json`（例如反馈问题时发给自己排查）。无数据时展示空态。
3. 不做任何网络发送、不接入第三方分析 SDK；隐私清单（PrivacyInfo.xcprivacy）
   无需新增「数据收集」声明——收集类型仍为「不收集」。

## 理由

- 侧载分发下没有 TestFlight/MetricKit 云端通道，只有订阅落盘这一条路能拿到诊断数据。
- MXDiagnosticPayload 是获取侧载 App 崩溃签名最省力的原生途径，实现成本约 0.3d（报告口径）。
- 「本地落盘 + 用户主动导出」与零遥测立场兼容：数据不出设备，除非用户亲手分享。

## 后果

- 诊断数据仅存在于设备本地；卸载 App 即全部丢失（导出需在卸载前完成）。
- metric payload 为每日聚合（启动耗时、卡顿率、内存等），崩溃诊断最多延迟到下次启动后投递，
  实时性有限——可接受，定位偶发问题足够。
- 若未来上架 App Store 并接入云端 MetricKit（ASC → 指标），本 ADR 的「仅本地」约束需升级版本重审。
