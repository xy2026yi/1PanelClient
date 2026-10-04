# 1PanelClient 迁移 Flutter（Android）指南

> 基于 v0.1.11（2026-08）源码盘点编写 · 盘点范围：`1PanelClient/`（App / PanelShared / PanelWidgets / Tests）
>
> 结论先行：**这是一次「按既有设计重写」，不是逐行移植**。Swift 与 Dart 无法共享代码，但本项目的分层（PanelShared 核心层与 UI 解耦、模型层完备、外部依赖极少）对重写非常友好。总体难度 **中高（★★★☆）**，熟练 Flutter 单人预计 **4 ~ 6 个月**，双人 **2.5 ~ 3.5 个月**。

---

## 目录

1. [项目现状盘点](#1-项目现状盘点)
2. [总体难度结论](#2-总体难度结论)
3. [技术映射总表](#3-技术映射总表)
4. [分层难度评估](#4-分层难度评估)
5. [逐模块难度与工作量](#5-逐模块难度与工作量)
6. [目标工程架构建议](#6-目标工程架构建议)
7. [关键技术点详解](#7-关键技术点详解)
8. [Swift → Dart 范式差异备忘](#8-swift--dart-范式差异备忘)
9. [分阶段迁移路线图](#9-分阶段迁移路线图)
10. [测试迁移](#10-测试迁移)
11. [无法 1:1 对应的功能](#11-无法-11-对应的功能)
12. [风险清单与规避](#12-风险清单与规避)

---

## 1. 项目现状盘点

### 1.1 规模

| 区域 | 文件数 | 行数 | 说明 |
|------|-------|------|------|
| `Features/`（20 个业务模块） | 61 | 40,648 | UI + ViewModel，迁移主体 |
| `PanelShared/`（核心层） | ~35 | 8,836 | 网络 / 存储 / 模型 / 通用组件 / Intents |
| `1PanelClient/`（App 壳） | 2 | 107 | App 入口 + ContentView |
| `PanelWidgets/`（小组件） | 4 | 335 | WidgetKit + App Intents |
| `1PanelClientTests/` | 14 | 1,201 | Swift Testing |
| **合计** | **153** | **51,127** | |

### 1.2 技术栈特征（影响迁移方式的关键点）

| 特征 | 现状 | 对迁移的影响 |
|------|------|------------|
| UI 框架 | SwiftUI，声明式 | → Flutter Widget 同为声明式，**心智模型一致**，逐组件翻译顺畅 |
| 状态管理 | `ObservableObject` + `@Published`（30 处），未用 `@Observable` | → Riverpod `Notifier` / `ChangeNotifier`，MVVM 结构可原样保留 |
| 导航 | `NavigationStack`（29 个文件）+ 半屏 sheet | → `go_router` 或直接 `Navigator`，sheet → `showModalBottomSheet` |
| 网络 | 自建 `APIClient`（URLSession × 3：常规 15s / SSE 流式 ∞ / 大文件传输），MD5 Token 签名 | → `dio` 三实例 + 拦截器，签名逻辑 10 行翻译完 |
| 实时通道 | WebSocket（终端、进程监控）、SSE（日志） | → `web_socket_channel`、dio 流式响应 |
| 凭据存储 | iOS Keychain（`KeychainStore`）+ App Group 共享 | → `flutter_secure_storage`（Android Keystore），同签名下天然共享 |
| 本地化 | `Localizable.xcstrings`（440KB，**约 5,300 条 key**）+ 自研 `L10n` | → `intl` + `.arb`，**写脚本转换**（见 §7.3） |
| 图表 | Swift Charts（3 处）+ GeometryReader 自绘（统一 Y 轴 / 时间轴） | → `fl_chart` + `CustomPainter`，自绘部分需重写 |
| 终端 | SwiftTerm（**唯一外部依赖**） | → `xterm.dart`，难度最高的单点 |
| 文件传输 | 分片 multipart 上传（5MB/片） | → dio + `file_picker`，逻辑可翻译 |
| 生物识别 | `LAContext` 应用锁 + 4 位密码回退 | → `local_auth` |
| 小组件 | WidgetKit + App Intents 交互式按钮 | → Android AppWidget（`home_widget` + 原生 Kotlin），需写平台代码 |
| 部署目标 | iOS 26.5 | Android 侧建议 minSdk 26（8.0），targetSdk 35+ |
| 现有脚本 | `scripts/migrate-l10n.py`、`sync-strings.py`（Python） | 迁移期间可复用思路 |

---

## 2. 总体难度结论

### 2.1 一句话结论

**难在「体量」，不难在「技术」。** 没有任何算法或架构障碍——网络协议（MD5 签名、WebSocket、SSE、分片上传）在 Dart 生态全有成熟等价物；唯一需要原生桥接的是 Android 桌面小组件。真正的成本是 4 万行业务 UI 的重写量与回归测试。

### 2.2 难度分级总览

| 迁移区域 | 难度 | 一句话理由 |
|----------|------|-----------|
| Models（Codable → Dart） | ★★☆ | 机械翻译，json_serializable 生成，但 21 个模型文件量大枯燥 |
| 网络层（APIClient/签名） | ★★☆ | 纯逻辑，dio 拦截器即可复刻，且有现成单测固定向量护航 |
| 存储（Keychain/ServerManager） | ★☆☆ | flutter_secure_storage 直接替换 |
| L10n（5,300 条） | ★★☆ | 写一次性 Python 脚本 xcstrings → arb，半天搞定 + 人工抽查 |
| 通用组件 / 设计系统（743 行 CommonComponents） | ★★★ | 自定义布局多，需逐个用 Widget 重写 |
| 20 个业务 UI 模块 | ★★★ | 单个不难，胜在量大约 4 万行，且要对照原版还原交互细节 |
| 图表（自绘统一坐标系） | ★★★ | CustomPainter 重写统一 Y 轴 / 时间轴 / 悬浮读数 |
| 终端（SwiftTerm → xterm.dart） | ★★★★ | 库替换 + WebSocket 管道 + 键盘辅助条（方向/Tab/Ctrl 组合） |
| 文件管理（分片上传/下载） | ★★★☆ | 逻辑可翻译，Android 文件选择器与进度通知需适配 |
| Android 桌面小组件 | ★★★★ | 无跨平台方案，须写 Kotlin（RemoteViews/Glance）+ MethodChannel |
| 多机管理全局状态跟随 | ★★★ | 节点切换需全局生效（CurrentNode 头 + operateNode 参数），Riverpod 全局状态正好适配 |
| 测试（14 个文件） | ★★☆ | Token/模型等纯逻辑测试可直接翻译 |

### 2.3 工期估算（熟练 Flutter 开发者）

| 阶段 | 内容 | 人日 |
|------|------|------|
| P0 | 工程脚手架 + 主题 + 导航骨架 | 4 |
| P1 | PanelShared 核心层（网络/存储/模型/L10n） | 15 ~ 20 |
| P2 | 首页 + 服务器管理 + 设置（可用最小闭环） | 12 ~ 15 |
| P3 | 核心业务模块（容器/应用/网站/数据库/证书） | 50 ~ 60 |
| P4 | 其余模块（Toolbox 系列/防火墙/计划任务/备份/日志/进程/终端） | 55 ~ 70 |
| P5 | 小组件 + 快捷入口（原生桥接） | 8 ~ 12 |
| P6 | 测试迁移 + Android 适配打磨 + 发布 | 15 ~ 20 |
| **合计** | | **约 160 ~ 200 人日** |

> 双人协作（一人核心层 + 模块，一人模块 + 原生桥接）可压缩至 **2.5 ~ 3.5 个月**。若接受首版裁剪（先做概览/容器/网站/终端等高频模块，P4 延后），**6 ~ 8 周可出首个可用版本**。

---

## 3. 技术映射总表

| iOS 现状 | Flutter/Dart 方案 | 备注 |
|----------|------------------|------|
| SwiftUI View | StatelessWidget / StatefulWidget | 声明式一一对应 |
| `ObservableObject` + `@Published` | Riverpod `Notifier`（推荐）或 `ChangeNotifier` | 保留 MVVM 分层 |
| `NavigationStack` / `navigationDestination` | `go_router`（推荐）或 `Navigator 1` | 深链可顺势支持 |
| `.sheet`（半屏） | `showModalBottomSheet` + `DraggableScrollableSheet` | 项目大量半屏操作面板 |
| Swift Charts | `fl_chart` | 折线/面积图够用 |
| GeometryReader 自绘 | `CustomPainter` | 统一坐标系需自绘 |
| URLSession（3 会话） | `dio` × 3（不同 timeout/baseOptions） | 拦截器注入签名头 |
| CryptoKit `Insecure.MD5` | `crypto` 包 `md5.convert()` | 见 §7.1 代码 |
| URLSessionWebSocketTask | `web_socket_channel` | 终端/进程监控 |
| SSE（URLSession bytes） | dio `ResponseType.stream` 逐行解析 | 日志查看 |
| Keychain | `flutter_secure_storage` | 底层 Android Keystore + EncryptedSharedPreferences |
| App Group 共享 | 同签名 applicationId 天然同进程可见 | Android 不需要 App Group |
| `LAContext`（FaceID/TouchID） | `local_auth` | 指纹/面容/虹膜 |
| UIKit 触觉 `UIImpactFeedbackGenerator` | `HapticFeedback`（内置类） | 无需插件 |
| SF Symbols | Material Icons 或 `flutter_svg` | 项目已自带一批 SVG 资产可直接复用 |
| `Localizable.xcstrings` | `intl` + `.arb` × 2 | 脚本转换，见 §7.3 |
| SwiftTerm | `xterm.dart`（pub 包 `xterm`） | 见 §7.5 |
| UIDocumentPicker | `file_picker` | 上传选文件 |
| WidgetKit Timeline | `home_widget` + AppWidgetProvider（Kotlin） | 见 §7.7 |
| App Intents（快捷指令/交互按钮） | Android App Shortcuts（`shortcuts.xml`）+ RemoteViews onClick | 交互式按钮走广播接收器 |
| os.log | `logger` 包 | |
| Swift Testing | `flutter_test` + `mocktail` | 固定向量直接翻译 |
| build-ipa.sh（免签 IPA） | `flutter build apk --release` / `appbundle` | Android 分发反而更简单 |

---

## 4. 分层难度评估

### 4.1 近乎机械翻译（低难度，约占 20% 工作量）

**Models 层（21 文件，含 PageResponse/APIResponse 信封）**
Swift `Codable` → Dart + `json_serializable`。要点：

- Swift 的 `let x: Int?` 可选解码宽容（缺 key 为 nil）对应 json_serializable 默认行为，**基本无痛**；
- Swift 自定义 `init(from:)` 的字段（如日期字符串解析、嵌套信封 `data` 解包）需手写工厂；
- `APIResponse<T>` / `PageResponse<T>` 泛型信封在 Dart 用泛型类 + `fromJson<T>(json, (d) => T.fromJson(d))` 模式。

**网络层（APIClient 521 行 + Endpoints + Error + ConnectionTester + SecurityGate ≈ 1,500 行）**
纯逻辑无 UI，dio 拦截器复刻签名头与 `CurrentNode` 头；三会话语义用三个 `Dio` 实例（不同 `BaseOptions`）对应。Token 签名是纯函数，现有 `APIClientTokenTests` 固定向量可先翻译，**用测试锁住正确性再迁业务**——这是整个迁移质量的关键杠杆。

**存储层（KeychainStore / ServerManager / NodeScope ≈ 1,000 行）**
`flutter_secure_storage` 全覆盖。注意：ServerManager 的「列表存 UserDefaults、凭据存 Keychain」拆分模式照搬为「列表存 `shared_preferences`、凭据存 secure_storage」。

### 4.2 换库重做（中难度）

**设计系统与通用组件（DesignTokens + CommonComponents 743 行 + Adaptive 适配层）**
颜色/间距/字体 Token 是常量表直接搬；`ServiceStatusCard`、`EllipsisMenu`、`LoadingStateView`、`MetricFormatters`（字节/百分比格式化）逐个重写为 Widget。量不大但决定后续所有页面的观感一致性，值得先做。

**图表**
三种来源：① Swift Charts（3 文件）→ `fl_chart` 直接表达；② 自绘统一坐标系（MonitorView/Overview 实时图，GeometryReader + Path）→ `CustomPainter` 重写，注意保留「统一 Y 轴与时间轴」的项目约定（`MonitorSlotWindowTests` 有窗口逻辑测试可翻译护航）；③ 32pt 指标环 → 简单 `CustomPainter`。

### 4.3 平台桥接（中高难度，需写 Kotlin）

- **Android 桌面小组件**（对应 ServerStatusWidget / QuickOpsWidget）：Flutter 侧无纯 Dart 方案，用 `home_widget` 包 + Android 原生 `AppWidgetProvider`（XML 布局 + RemoteViews）。数据链路：Dart 写入 `home_widget` 存储 → 原生读 → 30 分钟刷新策略用 `updatePeriodMillis` + `WorkManager`。
- **交互式按钮**（容器启停，iOS 走 App Intents）：Android 上用 RemoteViews `setOnClickPendingIntent` + `BroadcastReceiver` 回调 MethodChannel 唤起 Flutter 执行。QuickOpsWidget 是小组件里最难的一块，建议排在 P5 且首版可降级为「点击打开 App 对应页」。

### 4.4 纯 UI 重写（体量所在，约占 60% 工作量）

20 个模块的 View 树逐屏重画。有利因素：
- 原项目就是声明式 SwiftUI，`List`/`Form`/`sheet`/`toolbar` 的结构与 Flutter 的 `ListView`/`Column`+`Card`/`BottomSheet`/`AppBar` 几乎同构；
- 每个 ViewModel 的数据流（load → state → error）可原样翻成 Riverpod Notifier；
- `FEATURES.md` 有完整功能清单可当验收清单用。

不利因素：表单类页面（创建容器 3,476 行 Containers、创建数据库 1,017 行、Compose 参数对比等）字段多、联动多、校验多，是回归测试的重灾区。

---

## 5. 逐模块难度与工作量

> 行数 = `Features/` 下该目录 Swift 行数（含 ViewModel）。人日按熟练 Flutter 估算，含自测不含 QA。
> 难度：★☆☆ 翻译为主 / ★★★ 常规 UI / ★★★★ 涉及原生或复杂交互

| 模块 | 行数 | 难度 | 人日 | 迁移要点 |
|------|------|------|------|---------|
| Toolbox（监控/文件/Fail2ban/告警/SSH/WAF监控） | 8,508 | ★★★☆ | 25 ~ 30 | 最大的桶；监控图表 CustomPainter 重写；FilesView 分片上传（§7.6）；WAF 监控模型已有测试 |
| Websites（列表/配置/监控/SSL） | 5,071 | ★★★ | 15 ~ 20 | 表单与配置项极多；WebsiteConfigViews 912 行联动表单；监控图表复用统一坐标系组件 |
| Containers（列表/创建/详情/终端入口/监控） | 3,476 | ★★★☆ | 12 ~ 15 | 创建容器表单字段量大；1 秒轮询容器监控注意用 Timer + dispose 取消 |
| Apps（已安装应用/参数/日志/升级差异） | 2,893 | ★★★ | 10 ~ 12 | Compose 差异高亮对比（`ComposeDiffTests` 可翻译护航）、按块采用旧配置交互复杂 |
| Databases（MySQL/PG/Redis） | 2,785 | ★★★ | 9 ~ 11 | CreateDatabaseView 1,017 行动态表单；数据库终端走 WebSocket |
| Certificates（申请/上传/自签/CA/DNS） | 2,478 | ★★★ | 8 ~ 10 | 申请流程多步骤异步任务轮询 |
| Backups（账号/列表/快照） | 2,211 | ★★★ | 8 ~ 10 | 三类账号（MINIO/WebDAV/SFTP）表单 + 备份列表 |
| Manage（管理页分组 + 多机节点） | 2,079 | ★★★ | 7 ~ 10 | 多机管理全局状态（Riverpod 全局 NodeScope）+ 节点 CRUD/切换 |
| Cronjobs（任务/脚本库） | 1,781 | ★★★ | 6 ~ 8 | 多类型任务创建表单 + 执行记录日志 |
| Firewall（端口/IP 规则 + WAF 入口） | 1,713 | ★★★ | 6 ~ 8 | 单文件 1,713 行的 FirewallView 拆分为多个 Widget；`FirewallWhitelistTests` 护航 |
| Terminal（WebSocket 终端） | 1,394 | ★★★★ | 8 ~ 12 | SwiftTerm → xterm.dart（§7.5）；键盘辅助条（方向/Tab/Ctrl）；四种会话（主机/SSH/容器/数据库） |
| AppStore（商店安装/升级） | 1,047 | ★★★ | 5 ~ 7 | 与 Apps 模块联动，任务进度轮询 |
| Logs（四类日志查询 + SSE 查看） | 979 | ★★☆ | 4 ~ 5 | SSE 流式日志（§7.4） |
| Overview（首页概览） | 952 | ★★★ | 6 ~ 8 | 多卡片 + 实时图 + 5s 轮询 + 切回前台轻量刷新（WidgetsBindingObserver.resume） |
| Process（进程列表/详情） | 804 | ★★☆ | 3 ~ 4 | WebSocket 推送进程数据 + 排序 |
| Settings + AppLock | 664 | ★★☆ | 4 ~ 5 | local_auth 生物识别 + 4 位密码回退 + 递增锁定；退后台重锁（AppLifecycleListener） |
| Server（服务器列表/长按操作） | 647 | ★★★ | 4 ~ 5 | 5s 轮询、32pt 指标环、半屏长按面板（重启面板/服务器需输入确认） |
| Main（三 Tab 框架） | 402 | ★★☆ | 3 ~ 4 | NavigationBar + 子页面隐藏 Tab（用 go_router ShellRoute + 状态控制） |
| PanelWidgets（小组件） | 335 | ★★★★ | 8 ~ 12 | 原生 Kotlin 重写（§7.7），交互式按钮最难 |
| PanelShared 核心层 | 8,836 | ★★☆ | 15 ~ 20 | 见 §4.1：模型/网络/存储/L10n/通用组件 |
| Tests（14 文件） | 1,201 | ★★☆ | 5 ~ 7 | 见 §10 |
| 打磨（返回键/深色/横屏/性能） | — | ★★☆ | 10 ~ 15 | Android 返回手势 PopScope、边到边、预测式返回 |

---

## 6. 目标工程架构建议

### 6.1 目录结构（镜像现有分层，降低对照成本）

```
lib/
├── main.dart                     # 对应 _PanelClientApp.swift
├── app/                          # App 壳：路由、主题、生命周期
│   ├── router.dart               # go_router（对应 ContentView + NavigationStack）
│   ├── theme.dart                # DesignTokens 翻译：颜色/间距/暗色
│   └── app_lock_guard.dart       # AppLock 全局守卫
├── core/                         # 对应 PanelShared/Core
│   ├── network/
│   │   ├── api_client.dart       # dio × 3 + 签名拦截器
│   │   ├── api_endpoints.dart    # 常量表直接搬
│   │   ├── api_error.dart
│   │   └── connection_tester.dart
│   ├── storage/
│   │   ├── secure_store.dart     # KeychainStore 等价
│   │   ├── server_manager.dart
│   │   └── node_scope.dart       # 多机节点全局状态 → Riverpod
│   └── security_gate.dart        # 仅 HTTPS 开关
├── models/                       # 对应 PanelShared/Models（21 文件）
├── shared/                       # 对应 PanelShared/Shared
│   ├── widgets/                  # CommonComponents / ServiceStatusCard / EllipsisMenu
│   ├── charts/                   # 统一坐标系 CustomPainter 图表
│   ├── formatters/               # MetricFormatters
│   └── l10n/                     # arb 生成物
├── features/                     # 对应 Features/ 20 个目录，一一镜像
│   ├── overview/
│   ├── containers/
│   ├── terminal/
│   └── ...
└── intents/                      # 对应 PanelShared/Intents
    └── panel_intents.dart        # 供小组件/快捷方式调用的服务层
```

> 迁移期间保持 **iOS 目录 ↔ Flutter 目录同名同粒度**，对照审查效率最高；`archive/` 与本指南不动。

### 6.2 推荐依赖（pubspec.yaml）

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_localizations:
    sdk: flutter
  intl: ^0.19                     # L10n（arb 5,300 条）
  dio: ^5                         # 网络（三实例对应三 URLSession）
  crypto: ^3                      # MD5 Token 签名
  web_socket_channel: ^3          # 终端 / 进程监控
  flutter_secure_storage: ^9      # Keychain → Keystore
  shared_preferences: ^2          # 非敏感配置
  local_auth: ^2                  # 应用锁生物识别
  xterm: ^4                       # 终端模拟器（SwiftTerm 等价）
  fl_chart: ^0.69                 # 常规图表
  file_picker: ^8                 # 上传选文件
  home_widget: ^0.7               # Android 桌面小组件桥接
  flutter_riverpod: ^2            # 状态管理（全局节点状态、服务器列表）
  go_router: ^14                  # 导航
  flutter_svg: ^2                 # 复用现有 SVG 资产
  logger: ^2                      # os.log 等价

dev_dependencies:
  build_runner: ^2
  json_serializable: ^6
  flutter_test:
    sdk: flutter
  mocktail: ^1
```

选型说明：
- **Riverpod 而非 Bloc**：项目现有模式是「每模块一个 ViewModel 持状态 + 方法」，`Notifier` 翻译成本最低；且 `NodeScope`（当前操作节点全局生效）天生适合 `Provider` 跨模块读取。
- **go_router**：`ShellRoute` 解决「进子页隐藏底部 Tab」，对应现有三 Tab + 自动隐藏逻辑。

---

## 7. 关键技术点详解

### 7.1 Token 签名（先迁这个，用测试锁死）

Swift 现状（`APIClient.swift:55`）：`Token = MD5("1panel" + apiKey + timestamp)` 小写 hex。

Dart 等价（连同现有固定向量测试一起先写）：

```dart
import 'package:crypto/crypto.dart';

class PanelAuth {
  /// 1Panel v2: Token = MD5("1panel" + apiKey + timestamp)
  static String token(String apiKey, String timestamp) =>
      md5.convert(utf8.encode('1panel$apiKey$timestamp')).toString();

  static Map<String, String> headers(ServerConfig s) {
    final ts = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    return {
      '1Panel-Token': token(s.apiKey, ts),
      '1Panel-Timestamp': ts,
      'Content-Type': 'application/json',
      // 多机管理：当前节点（未设置 = local）
      if (NodeScope.headerValue(s.id) case final node?) 'CurrentNode': node,
    };
  }
}
```

dio 拦截器挂上 `headers()` 即完成全部接口的鉴权。**`APIClientTokenTests` 里的 MD5 固定向量原样翻译成 Dart 测试，第一天就让它是绿的。**

### 7.2 三会话语义

```dart
final api = Dio(BaseOptions(
  connectTimeout: Duration(seconds: 15),
  receiveTimeout: Duration(seconds: 30),
)); // 常规

final streamApi = Dio(BaseOptions(
  responseType: ResponseType.stream,
  receiveTimeout: null,           // SSE 日志长连接
));

final transferApi = Dio(BaseOptions(
  receiveTimeout: null,
  sendTimeout: Duration(seconds: 60), // 分片上传，整体不限时
));
```

注意保留原实现的两个细节：`httpShouldSetCookies = true` 但 `cookieStorage = nil`（会话内保活 cookie、不持久化）——dio 默认无 cookie 存储，行为接近，需在联调时验证登录态/会话接口；`operateNode` 查询参数优先级高于 `CurrentNode` 头（`APIClient.swift:72`），翻译时别丢。

### 7.3 L10n：xcstrings → arb（约 5,300 条，脚本化）

`Localizable.xcstrings` 是 JSON 格式，键值结构 `{ "key": { "localizations": { "zh-Hans": { "stringUnit": {"value": ...} }, "en": {...} } } }`。写一次性脚本：

```python
#!/usr/bin/env python3
# scripts/xcstrings_to_arb.py — Localizable.xcstrings → app_en.arb / app_zh.arb
import json, sys

src = json.load(open(sys.argv[1]))
for lang, out in [("zh-Hans", "app_zh.arb"), ("en", "app_en.arb")]:
    arb = {}
    for key, entry in src.get("strings", {}).items():
        v = entry.get("localizations", {}).get(lang, {}).get("stringUnit", {}).get("value")
        if v is not None:
            arb[key] = v
    json.dump(arb, open(out, "w", ensure_ascii=False, indent=2), ensure_ascii=False)
```

要点：
- Swift 的 `L10n.t("key")` → 生成代码里的 `AppL10n.key`（`flutter gen-l10n` 驼峰化），全局正则替换可半自动完成；
- `L10n.f(key, args)` 插值条目需检查 arb 占位符写法 `{name}`， xcstrings 格式串如 `%lld` / `%@` 要改写，**这类条目人工过一遍**（参考现有 `scripts/migrate-l10n.py` 的排查思路，它已经标记过含插值的条目）；
- 原项目「设置里切语言即时生效」在 Flutter 里用 `MaterialApp.router(locale: …)` + Riverpod 切换即可。

### 7.4 SSE 日志流

dio 流式响应逐行读：

```dart
final res = await streamApi.get<ResponseBody>(url, options: Options(responseType: ResponseType.stream));
final lines = res.data!.stream
    .transform(utf8.decoder)
    .transform(const LineSplitter());
await for (final line in lines) {
  if (line.startsWith('data:')) sink.add(line.substring(5).trim());
}
```

### 7.5 终端（SwiftTerm → xterm.dart，全项目最难单点）

- pub 包 `xterm` 提供 `Terminal` 模型 + `TerminalView` Widget，输入输出双向流对接 `web_socket_channel`；
- 四种会话（local/ssh/container/database 三端点）是纯 URL 构造逻辑（`TerminalSession.swift:55`），直接翻译；
- http→ws / https→wss 的 scheme 改写、`operateNode` 查询参数照搬；
- **键盘辅助条**（方向键 / Tab / Ctrl 组合）需自绘一行按钮 Widget，向 `Terminal` 实例注入 `keyEvent`；
- 已知差异：xterm.dart 的渲染性能与 SwiftTerm 相当，但触控选择文本的交互需要自己接 `TerminalView` 的手势；预算 2 天专门打磨。

### 7.6 文件分片上传

`FilesView.swift:64` 的 5MB 分片逻辑（seek → 读片 → multipart）在 Dart 里用 `File.openRead` + `Stream` 分段即可，dio 发 `FormData`。要点：
- 分片大小、`path` 字段、大小写与 1Panel v2 `/api/v2/files/upload` 对齐，联调时抓包对照 iOS 版；
- Android 侧 `file_picker` 选文件拿到 content URI，需先复制到缓存目录再分片（`File(path).openRead` 不认 URI）；
- 下载用 `dio.download`（transferApi 实例），Android 10+ 写入媒体/下载目录用 `saf` 或仅存 app 目录 + 用户手动分享，**比 iOS 的文件 App 沙盒模式更简单**。

### 7.7 Android 桌面小组件

无纯 Dart 方案，结构如下：

```
android/app/src/main/
├── res/xml/widget_info.xml          # 30min 刷新周期（对应 WidgetKit 时间线预算注释）
├── res/layout/widget_server.xml     # RemoteViews 布局
└── kotlin/.../
    ├── ServerStatusWidgetProvider.kt   # onUpdate 读 home_widget 数据渲染
    └── QuickOpsReceiver.kt             # 容器启停按钮 → MethodChannel 唤起后台 isolate
```

- 状态小组件：Dart 侧 `HomeWidget.saveData()` 写入 → Provider 读取渲染，`HomeWidget.updateWidget()` 触发刷新；
- 交互式容器按钮：RemoteViews `setOnClickPendingIntent` → `BroadcastReceiver` → `HomeWidget.runInteractWidgetCallback` / 后台 isolate 调 API。**首版可降级**：点击打开 App 的容器页由用户手动操作；
- iOS 的「App Group + 共享 Keychain」在 Android 不需要：同 applicationId 的 App 与 Widget 天然同进程签名，`flutter_secure_storage` 数据直接可见（未签名分发回退逻辑可整体删除）。

### 7.8 明文 HTTP 与「仅 HTTPS」开关

- Android 9+ 默认禁止 cleartext。对应现有 `SecurityGate`：
  - 默认（允许 HTTP）：`AndroidManifest` 加 `android:usesCleartextTraffic="true"` 或 `network_security_config.xml` 放行；
  - 「仅 HTTPS」开关开启时在 Dart 层 `SecurityGate` 拦截 `http://`（与 iOS 版同逻辑），并在 Manifest 保持放行——**拦截放应用层，不靠系统配置**，否则开关无法运行时切换；
- 自签名证书面板（1Panel 常见）需要 dio `BadCertificateCallback` 放行逻辑，iOS 版现状如何处理需对照 `ConnectionTester` 联调。

### 7.9 应用锁

`local_auth`（指纹/面容）+ 4 位数字密码回退逻辑纯 Dart 翻译。生命周期对应关系：iOS「退后台/锁屏即重锁」→ `AppLifecycleListener.onResume` 时校验；「锁定期清理内存敏感凭据」→ 清 Riverpod 内存缓存 + 可选 `flutter_secure_storage` 的 `deleteAll` 策略照搬 iOS 版语义。

---

## 8. Swift → Dart 范式差异备忘

| Swift | Dart | 陷阱 |
|-------|------|------|
| `struct` 值语义（模型复制即快照） | 一切皆引用 | 模型「拷贝后改字段不影响原值」的代码（如 Compose 差异「按块采用旧配置」）需显式 `copyWith` |
| `actor` / Swift 6 并发检查 | 单线程事件循环 + Isolate | 大部分并发问题消失；但**分片上传这类循环里更新 UI 进度**要回到主 isolate（默认就在），无需 dispatch |
| `async let` / TaskGroup | `Future.wait` | ServerCardMonitor 的并发任务组直译 |
| `Codable` 自定义键 | `@JsonKey(name:)` | snake_case 映射批量加 |
| `@MainActor` ViewModel | Riverpod Notifier 默认主线程 | 心智一致 |
| 弱引用 `weak var` 防循环 | 无需 | GC 兜底 |
| `guard let` 早退 | `if (x case final v?)` / 提前 return | 模式匹配写法适应期 |
| result builder（ViewBuilder） | Widget 构建函数里 if/for 直接写 | 更自由，无需收集容器 |
| KVO/Combine | Stream / Riverpod | 项目未用 Combine，无负担 |

---

## 9. 分阶段迁移路线图

每个阶段结束都有**可运行、可演示**的产物；顺序原则：先核心层（测试护航）→ 最小业务闭环 → 高频模块 → 长尾 → 原生桥接。

### Phase 0：脚手架（约 1 周）
- [ ] Flutter 工程初始化（minSdk 26，空安全，CI 跑 `flutter analyze + test`）
- [ ] 主题系统（DesignTokens 翻译：亮/暗色）、三 Tab 骨架 + 子页隐藏 Tab
- [ ] xcstrings → arb 转换脚本跑通，中英切换生效
- **验收：App 可启动，三 Tab 空页，语言/暗色可切换**

### Phase 1：核心层（约 2 周）
- [ ] Models 21 文件（json_serializable）+ 信封/分页泛型
- [ ] APIClient（dio × 3 + 签名拦截器 + SecurityGate + ConnectionTester）
- [ ] SecureStore / ServerManager / NodeScope
- [ ] **翻译 Token / APIResponse / Keychain / SecurityGate / PageResponse 五个测试文件并保持全绿**
- **验收：可以添加服务器并通过连接测试；测试覆盖核心层**

### Phase 2：最小闭环（约 2 周）
- [ ] 服务器列表页（5s 轮询 + 指标环）+ 添加/编辑/删除 + 长按半屏操作
- [ ] 首页概览（资源卡片 + 实时图表 + 系统信息 + 证书倒计时）
- [ ] 设置页 + 应用锁（local_auth）
- **验收：单服务器完整使用路径可用 —— 此时即可发内测包收集反馈**

### Phase 3：高频模块（约 4 ~ 5 周）
- [ ] 容器（列表/创建/详情/监控）→ 应用与商店 → 网站 → 数据库 → SSL 证书
- [ ] 期间同步翻译 ComposeDiff / WAFMonitor / WebsiteMonitor 等模型测试
- **验收：日常运维操作（启停容器、装应用、改站点）全通**

### Phase 4：长尾模块（约 4 ~ 5 周）
- [ ] 终端（xterm.dart，预留打磨时间）→ 文件 → 监控 → 防火墙/Fail2ban/WAF → 计划任务 → 备份 → 日志/进程/告警/多机管理
- **验收：FEATURES.md 清单逐项勾完**

### Phase 5：小组件 + 收尾（约 2 ~ 3 周）
- [ ] Android 小组件（状态卡片先行，交互式按钮视情况降级）
- [ ] Android 适配打磨：返回手势（PopScope/预测式返回）、边到边、深色、横屏/平板、应用图标自适应
- [ ] 版本号策略对齐、发布渠道（GitHub Release + APK）
- **验收：对外发布 v1.0**

> 每阶段建议在 `doc/` 下追加一份 Flutter 版 FEATURES 勾选清单，用 iOS 版 `FEATURES.md` 做验收基线。

---

## 10. 测试迁移

现有 14 个 Swift Testing 文件（1,201 行）按性质分三类处理：

| 类型 | 文件 | 迁移方式 |
|------|------|---------|
| 纯逻辑（必须先迁） | APIClientTokenTests（MD5 固定向量）、APIResponseTests、PageResponseEmptyTests、ComposeDiffTests、MonitorSlotWindowTests、FirewallWhitelistTests、NodeModelsTests、WebsiteMonitorModelsTests、WAFMonitorModelsTests | 直接翻译成 `flutter_test`，向量/断言原样保留。**Phase 1 完成 Token + 信封两个，其余随所属模块迁** |
| 平台相关 | KeychainStoreTests | 改测 `flutter_secure_storage` 封装层（语义相同：增删改查、锁定期清理） |
| UI/文案 | L10nTests、AdaptiveLayoutTests、PanelIntentsTests、ServerConfigAndSecurityGateTests | L10n 改测 arb 加载完整性；Adaptive 改 Flutter 布局断言；Intents 随小组件阶段重写 |

新增建议（原版没有的）：dio 拦截器单测（签名头/CurrentNode 头/operateNode 参数优先级）、分片上传切片边界测试。

---

## 11. 无法 1:1 对应的功能

| iOS 功能 | Android 等价 / 处置 |
|----------|-------------------|
| LiveContainer 免签分发 / build-ipa.sh | 不需要 —— Android 直接分发 APK/AAB，`flutter build apk --release` 即可；构建脚本反而大幅简化 |
| App Group + 共享 Keychain（小组件共享凭据） | 同 applicationId 天然共享，相关「未签名回退」代码删除 |
| App Intents / 快捷指令 App 集成 | App Shortcuts（shortcuts.xml，静态即可覆盖「打开某服务器」级别）；深度自动化暂无等价物，首版不做 |
| 交互式小组件按钮（App Intents Timeline） | RemoteViews + BroadcastReceiver 可做到，但体验不同，列入 P5 高风险项 |
| FaceID / TouchID 文案 | local_auth 自动映射指纹/面容/虹膜，文案改用系统术语 |
| SF Symbols | 换 Material Icons；项目自带 SVG（docker/mysql/redis 等 brand 图标）用 flutter_svg 直接复用 |
| iPad 适配（IPAD-ADAPTATION.md） | 对应 Android 平板 = 响应式断点，Flutter 单代码即可，成本低于 iOS 版 |
| iOS 26 Liquid Glass 等新 API 视觉 | 无等价，用 Material 3 表达；建议借机统一为 Material 风格而非逐像素复刻 iOS 观感 |

---

## 12. 风险清单与规避

| # | 风险 | 概率 | 影响 | 规避 |
|---|------|------|------|------|
| 1 | **体量失控**：20 模块重写战线长，中途 iOS 版继续迭代导致双线追赶 | 高 | 高 | 锁定基线版本（如 v0.1.11 的 FEATURES.md 为验收基线）；iOS 新功能冻结或排期延后合入；每阶段发内测 |
| 2 | 表单回归遗漏：容器/数据库/网站创建表单字段多 | 高 | 中 | 用 FEATURES.md + 逐屏截图对照走查；对建表单类页面写 Widget 测试（填默认值可提交） |
| 3 | xterm.dart 体验不及 SwiftTerm（触控选择、性能） | 中 | 中 | Phase 4 预留 2 天打磨；保底方案：终端首版仅支持基础输入输出 |
| 4 | 交互式小组件（容器启停）原生链路踩坑 | 中 | 中 | 首版降级为「点击打开 App 对应页」，交互式按钮作为后续版本 |
| 5 | cookie / 会话语义差异（dio vs URLSession）导致部分接口 401 | 中 | 中 | Phase 1 联调用真机面板抓包对照 iOS 版请求头；必要时引入 `cookie_jar` 内存版 |
| 6 | 5300 条文案插值格式（%@ vs {name}）转换出错 | 中 | 低 | 脚本 + 人工抽查插值条目；L10n 完整性测试（遍历 arb 断言无占位符残留错误） |
| 7 | 明文 HTTP / 自签证书在 Android 各版本行为不一 | 中 | 中 | network_security_config 显式声明；SecurityGate 应用层拦截为唯一真相源；真机矩阵覆盖 8/12/14/15 |
| 8 | 双平台长期双份代码维护成本 | 高 | 高 | 明确策略：Flutter 版仅面向 Android（iOS 继续原生），或 18 个月内评估 Flutter 版反哺替换 iOS 版；避免三端两套技术栈并行太久 |
| 9 | Riverpod 全局节点状态遗漏注入（CurrentNode 头）导致多机操作打错节点 | 低 | 高 | dio 拦截器统一注入（唯一入口）+ 专门单测断言头存在；`operateNode` 优先级测试 |

---

## 附：迁移期间可复用的现有资产

- **直接复用**：全部 SVG/PNG 图标资产（Assets.xcassets → Flutter assets）、API 端点常量表（`APIEndpoints.swift` 手动搬）、FEATURES.md 验收清单、L10n 键名体系（arb 直接沿用原 key，减少对照成本）；
- **翻译复用**：21 个模型文件、Token/信封/分页等 9 个纯逻辑测试的断言向量；
- **思路复用**：`scripts/migrate-l10n.py` 的「插值条目人工清单」输出方式，搬到 arb 转换脚本里。

---

*文档生成于 2026-08-23，基于 main 分支 a90c0ac（v0.1.11）源码盘点。若 iOS 版本后续大改，请以 FEATURES.md 的对应版本为基线同步更新本指南。*
