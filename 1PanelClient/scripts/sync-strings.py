#!/usr/bin/env python3
r"""
sync-strings.py — L10n 字符串目录同步工具

配合 Shared/Localization/L10n.swift 使用（key = 简体中文原文）。
因为 L10n.t()/f() 是运行时查表，Xcode 无法静态提取 key，本脚本补齐该环节。

用法（在 1PanelClient/ 目录下运行）：
  python3 scripts/sync-strings.py                     # 扫描源码，同步 key 进 xcstrings（保留已有翻译）
  python3 scripts/sync-strings.py --prune             # 额外删除 xcstrings 中未被源码引用的 key
  python3 scripts/sync-strings.py --apply FILE.json   # 从 JSON（{key: en翻译}）应用英文翻译
  python3 scripts/sync-strings.py --check             # CI 模式：不写文件，仅报告缺失/未用/未翻译

规则：
  - 提取 L10n.t("…") / L10n.f("…") 的字符串字面量（含转义解析）
  - 含插值 \(…) 的字面量视为迁移遗漏，报告 ERROR（应改用 L10n.f + %@ 占位）
  - 新 key 以 state "new" 写入；已有条目保持不动（翻译不丢）
"""

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # 1PanelClient/
SRC_DIRS = [ROOT / "1PanelClient", ROOT / "PanelShared"]
XCSTRINGS = ROOT / "PanelShared" / "Shared" / "Localization" / "Localizable.xcstrings"

# 运行时动态查表的 key（enum rawValue 经 L10n.t(x.rawValue) 使用，静态扫描不可见）
# 动态引用白名单：经「独立带引号字面量」验证为动态喂入 L10n 的键
#（三元首参 / 枚举 rawValue / 本地元组表），静态提取器抓不到，勿手动删减
DYNAMIC_KEYS = {
    "*",
    "-",
    "..",
    "/home/user/privkey.pem",
    "/var/log/auth.log",
    "100",
    "1000",
    "1Panel",
    "1Panel Client",
    "1Panel Server",
    "200",
    "30",
    "360搜索",
    "500",
    "Body",
    "CDN",
    "Container",
    "DNS",
    "Discord",
    "Docker",
    "FTP",
    "Fail2ban",
    "GB",
    "GitHub",
    "HSTS",
    "HTTP",
    "HTTP/3 (QUIC)",
    "HTTPS",
    "Headers",
    "Hosts",
    "IPv4",
    "IPv6",
    "Innodb索引命中率",
    "KB",
    "New",
    "Ollama",
    "QQ",
    "Redis 的内存消耗峰值",
    "SOCKS5",
    "SWAP",
    "Scheduled Task",
    "TLSv1.2",
    "TLSv1.3",
    "TTY",
    "Telegram",
    "Token",
    "URL",
    "User-Agent",
    "WAF",
    "Website",
    "docker-compose",
    "docker-compose.yml",
    "experimental",
    "ext4",
    "file.txt",
    "folder_name",
    "gzip",
    "ip6tables",
    "iptables",
    "nginx.conf",
    "sshd_config",
    "unix:///var/run/docker.sock",
    "vLLM",
    "xfs",
    "·",
    "—",
    "••••••••",
    "…",
    "不授权",
    "今日头条",
    "任务「%@」停用失败：%@",
    "任务「%@」启用失败：%@",
    "内存",
    "内存碎片率",
    "分钟",
    "创建",
    "创建临时表到磁盘",
    "卸载插件 %@",
    "压缩率",
    "反向代理已保存",
    "反向代理已创建",
    "发送",
    "名称",
    "向操作系统申请的内存大小",
    "启动 / 停止 / 重启 / 关闭指定容器",
    "启动或停止指定网站",
    "在线检查与 CPU / 内存 / 负载概览",
    "客户端请求的头buffer大小",
    "容器操作",
    "小时",
    "已停用 %ld 个任务",
    "已关闭 SSL",
    "已关闭反向代理",
    "已关闭密码访问",
    "已关闭流量限制",
    "已关闭重定向",
    "已启用 %ld 个任务",
    "已开启 SSL",
    "已开启反向代理",
    "已开启密码访问",
    "已开启流量限制",
    "已开启重定向",
    "已打开表",
    "已运行天数",
    "当前 Redis 使用的内存大小",
    "当前监听端口",
    "必应",
    "总连接数",
    "所有人(%)",
    "手动触发一次计划任务",
    "手机上传",
    "执行计划任务",
    "指定IP",
    "排序后的合并次数",
    "接收",
    "搜狗",
    "日志",
    "更新插件 %@",
    "更新（%ld）",
    "更新（所有）",
    "最大上传文件",
    "最小压缩文件",
    "最近一次 fork() 操作耗费的微秒数",
    "服务器名字的hash表大小",
    "服务器文件",
    "服务器概览",
    "服务器每秒钟执行的命令数量",
    "机构详情",
    "查找数据库键命中率",
    "查找数据库键失败的次数",
    "查找数据库键成功的次数",
    "查询缓存命中率",
    "检查服务器状态",
    "每周",
    "每天",
    "每小时",
    "每月",
    "每秒事务",
    "每秒查询",
    "没有使用索引的量",
    "没有索引的JOIN量",
    "留空使用当前服务器",
    "百度",
    "神马搜索",
    "私钥",
    "秒",
    "粘贴内容",
    "索引命中率",
    "线程缓存命中率",
    "网站启停",
    "网站操作",
    "网络",
    "证书",
    "证书信息",
    "读取 CPU / 内存 / 负载的当前值",
    "账号已保存",
    "账号已创建",
    "运行以来执行过的命令的总数量",
    "运行以来连接过的客户端的总数量",
    "进程",
    "连接的客户端数量",
    "连接超时时间",
    "选择",
    "重定向已保存",
    "重定向已创建",
    "锁表次数",
}

CALL_RE = re.compile(r'L10n\.[tf]\s*\(\s*"')
# 字符串字面量扫描：起始引号后逐字符处理转义与插值
LIT_START = re.compile(r'"')


def extract_keys_from_source(text: str, rel: str, errors: list) -> set:
    """提取一个源文件中 L10n.t/f 调用的字面量 key 集合。"""
    keys = set()
    for m in CALL_RE.finditer(text):
        i = m.end()  # 指向起始引号后的第一个字符
        buf = []
        has_interp = False
        while i < len(text):
            c = text[i]
            if c == "\\":
                nxt = text[i + 1] if i + 1 < len(text) else ""
                if nxt == "(":
                    has_interp = True
                    depth = 1
                    j = i + 2
                    while j < len(text) and depth:
                        if text[j] == "(":
                            depth += 1
                        elif text[j] == ")":
                            depth -= 1
                        j += 1
                    i = j
                    continue
                esc = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}.get(nxt, nxt)
                buf.append(esc)
                i += 2
                continue
            if c == '"':
                break
            buf.append(c)
            i += 1
        key = "".join(buf)
        if has_interp:
            errors.append(f"{rel}: L10n.t/f 字面量含插值，请改用 L10n.f 占位符: {key[:40]}…")
            continue
        if key:
            keys.add(key)
    return keys


def swift_unescape(s: str) -> str:
    return s


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--prune", action="store_true", help="删除 xcstrings 中未被引用的 key")
    ap.add_argument("--apply", type=Path, help="从 JSON 文件应用英文翻译")
    ap.add_argument("--check", action="store_true", help="只报告，不修改文件")
    args = ap.parse_args()

    errors, warnings = [], []
    keys = set()
    for d in SRC_DIRS:
        for f in sorted(d.rglob("*.swift")):
            rel = f.relative_to(ROOT)
            keys |= extract_keys_from_source(f.read_text(encoding="utf-8"), str(rel), errors)

    catalog = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings: dict = catalog.get("strings", {})
    catalog["sourceLanguage"] = "zh-Hans"

    applied = 0
    if args.apply:
        table = json.loads(args.apply.read_text(encoding="utf-8"))
        for k, v in table.items():
            entry = strings.setdefault(k, {"extractionState": "manual", "localizations": {}})
            locs = entry.setdefault("localizations", {})
            locs["en"] = {"stringUnit": {"state": "translated", "value": v}}
            applied += 1

    added = 0
    for k in sorted(keys):
        if k in strings:
            continue
        strings[k] = {
            "extractionState": "manual",
            "localizations": {"en": {"stringUnit": {"state": "new", "value": ""}}},
        }
        added += 1

    unused = sorted(set(strings) - keys - DYNAMIC_KEYS)
    pruned = 0
    if args.prune:
        for k in unused:
            del strings[k]
            pruned += 1
    elif unused:
        for k in unused[:20]:
            warnings.append(f"xcstrings 中未被引用: {k}")
        if len(unused) > 20:
            warnings.append(f"… 及另外 {len(unused) - 20} 条（--prune 清理）")

    untranslated = sorted(
        k for k, v in strings.items()
        if not v.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")
    )

    catalog["strings"] = {k: strings[k] for k in sorted(strings)}
    if not args.check:
        XCSTRINGS.write_text(
            json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : ")) + "\n",
            encoding="utf-8",
        )

    print(f"源码 key: {len(keys)}  目录条目: {len(strings)}  新增: {added}  pruned: {pruned}  应用翻译: {applied}")
    print(f"未翻译(en 为空): {len(untranslated)}")
    for e in errors:
        print(f"ERROR  {e}")
    for w in warnings:
        print(f"WARN   {w}")
    if errors:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
