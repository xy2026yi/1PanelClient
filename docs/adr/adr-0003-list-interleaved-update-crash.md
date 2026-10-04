# ADR-0003：SwiftUI List 交错更新崩溃（invalid number of items）的处置决策

日期：2026-09-24 ｜ 状态：已采纳 ｜ 关联：TEST-CHECKLIST「删除用户卡死」四轮攻坚

## 背景

删除 MySQL 数据库用户时，List 抛出 `NSInternalInconsistencyException: Invalid update:
invalid number of items in section …` 并闪退。崩溃签名恒定：**删除 diff 动画应用期间，
dataSource 的条目数与预期不符**（如 before=2、deleted=1、after 却仍为 2）。

## 四轮尝试与结论

| 轮次 | 策略 | 结果 |
|---|---|---|
| 1 | 移除本地 `removeAll`、只走整表 reload | 仍崩 |
| 2 | 删除请求前等确认 Sheet 收起动画 500ms | 仍崩 |
| 3 | 请求先行 + users/grants 两表一次 `withTransaction(animation: nil)` 同步赋值 | 仍崩 |
| 4 | 用户节挂 `.id(usersReloadToken)`，删除后整节**身份重建** | ✅ 通过 |

## 决策

1. **凡「删除条目 + 同页多 @Published 数据源」的 List，删除后走整节身份重建**
   （`.id(token)`，token 随数据一并写入同一事务）。重建走 reload 路径，
   `invalid number of items` 断言只存在于增量 diff 批量增删路径，机制上绕开。
2. 重建会丢滚动位置——调用方在删除前记录相邻行锚点，`onChange(of: token)` 后回滚。
3. **禁止**在同一运行循环内对多个 @Published 列表做跨 await 的分步赋值
   （即便有轮次 3 的单事务写入也未除根，不要再走回头路）。

## 教训

- 崩溃签名（ UICollectionView 层的批量更新断言）比代码直觉可靠：三轮"时序修复"
  都在猜交错源，第 4 轮停止猜、直接消灭增量路径才收口。
- 疑似同类场景（多数据源同页 List + 删除动画）应直接采用本决策，不必重复试错。
