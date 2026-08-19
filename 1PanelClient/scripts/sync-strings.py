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
SRC_DIRS = [ROOT / "1PanelClient"]
XCSTRINGS = ROOT / "1PanelClient" / "Shared" / "Localization" / "Localizable.xcstrings"

# 运行时动态查表的 key（enum rawValue 经 L10n.t(x.rawValue) 使用，静态扫描不可见）
DYNAMIC_KEYS = {
    "不授权", "内存", "分钟", "创建", "名称", "小时", "所有人(%)", "指定IP", "日志", "服务器文件", "机构详情", "每周", "每天", "每小时", "每月", "私钥", "秒", "粘贴内容", "网络", "证书", "证书信息", "进程", "选择",
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
