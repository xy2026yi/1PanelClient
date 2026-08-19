#!/usr/bin/env python3
r"""
migrate-l10n.py — 硬编码中文文案 → L10n 调用的半自动迁移工具

对给定 Swift 文件：
  1. 无插值的含中文字符串字面量 → 包装为 L10n.t("…")
  2. 含 \(…) 插值的含中文字面量 → 不动，输出 TODO 清单（需人工改 L10n.f + 占位符）

排除（不包装）：
  - 行注释 / 块注释内部
  - 已在 L10n.t( / L10n.f( 内部
  - 紧邻比较运算符（== != ，多为 API 原始值匹配，包装会改变语义）
  - 含中文的 format/dateFormat 等非文案字面量（按 key 名排除，见 NON_L10N_KEYS）

用法：python3 scripts/migrate-l10n.py FILE [FILE...]
"""

import re
import sys
from pathlib import Path

CN = re.compile(r"[\u4e00-\u9fff]")
LIT = re.compile(r'"')

# 这些参数名下的中文字面量不是 UI 文案（API 值/格式串等）
NON_L10N_KEY_RE = re.compile(
    r'(?:dateFormat|format|locale|identifier|timezone|CodingKeys|rawValue|unit)\s*[:=]\s*$',
    re.IGNORECASE,
)


def strip_comments(text: str) -> str:
    """把注释区替换为等长空白，供位置遮蔽；字符串字面量内的 // 与 /* 需保留。"""
    out = list(text)
    i, n = 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            if text[i : i + 3] == '"""':
                end = text.find('"""', i + 3)
                i = n if end == -1 else end + 3
                continue
            in_str = True
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = i
            while j < n and text[j] != "\n":
                out[j] = " "
                j += 1
            i = j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = i + 2
            while j + 1 < n and not (text[j] == "*" and text[j + 1] == "/"):
                if text[j] != "\n":
                    out[j] = " "
                j += 1
            if j + 1 < n:
                out[i] = out[i + 1] = " "
                out[j] = out[j + 1] = " "
                j += 2
            i = j
            continue
        i += 1
    return "".join(out)


def migrate(path: Path) -> int:
    text = path.read_text(encoding="utf-8")
    masked = strip_comments(text)
    todos = []
    out = list(text)
    replaced = 0
    n = len(text)
    i = 0
    while i < n:
        # 只处理非注释区的引号（masked 抹掉了注释，保留字符串字面量）
        if text[i] != '"' or masked[i] != '"':
            i += 1
            continue
        # 找字面量结束（处理转义与插值）
        j = i + 1
        has_interp = False
        while j < n:
            c = text[j]
            if c == "\\":
                if j + 1 < n and text[j + 1] == "(":
                    has_interp = True
                    depth, k = 1, j + 2
                    while k < n and depth:
                        if text[k] == "(":
                            depth += 1
                        elif text[k] == ")":
                            depth -= 1
                        k += 1
                    j = k
                    continue
                j += 2
                continue
            if c == '"':
                break
            j += 1
        lit = text[i : j + 1]
        if not CN.search(lit):
            i = j + 1
            continue

        # 上下文用原始文本（紧邻的 L10n.t( / 运算符判定不受注释遮蔽影响）
        prefix = text[:i]
        line_start = prefix.rfind("\n") + 1
        before = prefix[line_start:i].rstrip()

        # 已在 L10n.t( / L10n.f( 内部？
        if re.search(r'L10n\.[tf]\s*\(\s*$', prefix):
            i = j + 1
            continue
        # 比较运算符上下文（API 原始值匹配），不包装；?. 与 as? 是可选链，也排除
        if re.search(r'(==|!=|\.contains\(|hasPrefix\(|hasSuffix\(|\?\.|as\?)\s*$', before):
            i = j + 1
            continue
        # 指定参数名上下文
        key_ctx = re.search(r'([A-Za-z_][A-Za-z0-9_]*)\s*[:=]\s*$', before)
        if key_ctx and NON_L10N_KEY_RE.search(before):
            i = j + 1
            continue

        if has_interp:
            todos.append(f"{path.relative_to(path.parents[2])}: 插值待人工: {lit[:60]}")
            i = j + 1
            continue

        # 包装：保持原字面量，前加 L10n.t(
        out[i] = f'L10n.t({text[i]}'
        out[j] = f'{text[j]})'
        replaced += 1
        i = j + 1

    if replaced or todos:
        path.write_text("".join(out), encoding="utf-8")
    print(f"{path.name}: 包装 {replaced} 处")
    for t in todos:
        print(f"  TODO {t}")
    return replaced


if __name__ == "__main__":
    total = 0
    for arg in sys.argv[1:]:
        total += migrate(Path(arg))
    print(f"合计包装 {total} 处")
