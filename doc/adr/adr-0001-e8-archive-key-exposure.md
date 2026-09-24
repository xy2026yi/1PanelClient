# ADR-0001：archive 归档脚本中的真实 API 密钥处置（审计项 E8）

- 日期：2026-09-06
- 状态：已接受（含一项待人工执行：面板侧轮换密钥，见下）
- 关联：`docs/project-audit-report-2026-09.md` §6-E8、§7-P0

## 背景

项目评估（2026-09-06）发现 `archive/` 下 8 个已被 git 跟踪的脚本含有真实 1Panel API 密钥赋值
（同一把密钥，指向 Parallels 虚拟机 `10.211.55.4:36130` 的测试面板）：

| 文件 | 处置 |
|---|---|
| `archive/logs/sample_responses.sh` | 本次改为 `${1PANEL_API_KEY:?…}` 环境变量读取 |
| `archive/logs/sample_responses2.sh` | 同上 |
| `archive/logs/fetch_swagger.sh` | 同上 |
| `archive/logs/probe_endpoints.sh` | 同上 |
| `archive/logs/images/run1.sh` | 同上 |
| `archive/doc/get_log_op.py` | 本次改为占位符 `1PANEL_API_KEY` |
| `archive/doc/1panel_install_new_app.py` | 同上 |
| `archive/logs/get_loc_mess.py` | 早前已自行脱敏（无需处理） |

正面事实（评估确认）：仓库无 `.env`/`.key`/`.pem` 跟踪文件；App 源码与日志零密钥输出。

## 决策

1. **工作区脱敏**（已完成）：上述 7 处密钥字面量全部移除，运行时经环境变量
   `1PANEL_API_KEY` 注入或手动替换占位符。
2. **面板侧轮换密钥**（⚠️ 待人工执行，唯一能让历史暴露失效的手段）：
   在 1Panel 面板「面板设置 → API 接口」禁用并重新生成该密钥。旧密钥随即失效，
   git 历史中翻出的字符串不再可用。
3. **不改写 git 历史**：评估明确指出仅改工作区不够（历史 commit 仍可翻出），但历史改写
   （filter-repo/BFG）会使所有已有克隆的校验失效、需强制同步，代价与收益不成比例——
   该密钥仅能访问一台本地测试虚拟机的面板，轮换后历史暴露即失去价值。据此选择
   **接受历史暴露 + 立即轮换** 的处置。

## 后果

- 轮换完成前，任何能读到本仓库的人仍可用旧密钥操作该测试面板（仅限该 VM，无生产数据）。
- 轮换后，历史中的密钥字符串成为无害死数据；后续审计以「密钥是否已轮换」为本 ADR 的
  唯一遗留检查项（并入 `docs/manual-verification-checklist-2026-09.md`）。
- 归档脚本若需重新运行，先 `export 1PANEL_API_KEY=<新密钥>`。

## 教训

抓包/探测类脚本入库前必须走占位符或环境变量；建议后续在 CI 加
`git ls-files | xargs grep -l 'API_KEY="[^$]'` 类守门检查。
