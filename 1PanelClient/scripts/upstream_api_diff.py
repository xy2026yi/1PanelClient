#!/usr/bin/env python3
"""
upstream_api_diff.py —— 1Panel 上游版本 API 变更 diff（三源之法·源码源）

用法:
    python3 scripts/upstream_api_diff.py v2.2.5 v2.3.0 [--module firewall] [--out report.md]

做什么:
    1. 下载并解压两个 tag 的源码包（缓存于 ~/.cache/1panel-diff，重复运行不重下）
    2. 提取两版全部路由注册并对照（端点增删；--module 按关键字过滤）
    3. diff agent/app/dto/*.go —— DTO 层变更规模与类型增删
    4. 产出 Markdown 报告，供适配分诊

这是 doc/references/1panel-upstream-adaptation-roadmap-2026-09.md 月度 SOP 的工具化；
抓包验证与 Swagger 对比为另外两源，需面板环境。
"""

import argparse
import difflib
import os
import re
import sys
import tarfile
import urllib.request
from pathlib import Path

REPO = "1Panel-dev/1Panel"
CACHE = Path("~/.cache/1panel-diff").expanduser().resolve()

# git tag 白名单：字母数字与 . - _（拒绝路径穿越）
TAG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
# 路由注册行（gin：xxxRouter.METHOD("path", handler)）
ROUTE_RE = re.compile(r'\w*[Rr]outer\.\w+\(\s*"(/[^"]*)"')


def ensure_source(tag: str) -> Path:
    """下载并解压指定 tag 的源码，返回解压后目录（tag 先过白名单，路径锁定在缓存目录内）"""
    if not TAG_RE.match(tag):
        sys.exit(f"非法 tag：{tag!r}（仅允许字母数字与 . - _）")
    target = (CACHE / f"1Panel-{tag.lstrip('v')}").resolve()
    if not target.is_relative_to(CACHE):
        sys.exit("解压路径越界，已拒绝")
    if target.is_dir():
        return target
    CACHE.mkdir(parents=True, exist_ok=True)
    tgz = CACHE / f"{tag}.tar.gz"
    if not tgz.exists():
        url = f"https://github.com/{REPO}/archive/refs/tags/{tag}.tar.gz"
        print(f"下载 {url} ...", file=sys.stderr)
        urllib.request.urlretrieve(url, tgz)
    # 解压成员同样锁定缓存目录（防 tar 包内含 ../ 的成员）
    with tarfile.open(tgz) as tf:
        for member in tf.getmembers():
            member_path = (CACHE / member.name).resolve()
            if not member_path.is_relative_to(CACHE):
                sys.exit(f"tar 成员越界，已拒绝：{member.name}")
        tf.extractall(CACHE)
    return target


def read_lines(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8").splitlines(keepends=True)
    except OSError:
        return []


def extract_routes(base_dir: Path, new_dir: Path) -> tuple[set[str], set[str]]:
    """全量提取两版的路由注册（文件: path）"""
    def routes(dirpath: Path) -> set[str]:
        result: set[str] = set()
        router_dir = dirpath / "agent" / "router"
        if not router_dir.is_dir():
            return result
        for go_file in sorted(router_dir.glob("*.go")):
            for line in read_lines(go_file):
                m = ROUTE_RE.search(line)
                if m:
                    result.add(f"{go_file.name}: {m.group(1)}")
        return result

    return routes(base_dir), routes(new_dir)


def dto_diff(base_dir: Path, new_dir: Path) -> list[str]:
    out = []
    base_sub, new_sub = base_dir / "agent/app/dto", new_dir / "agent/app/dto"
    base_names = {p.name for p in base_sub.glob("*.go")} if base_sub.is_dir() else set()
    new_names = {p.name for p in new_sub.glob("*.go")} if new_sub.is_dir() else set()
    for fn in sorted(base_names | new_names):
        bl = read_lines(base_sub / fn)
        nl = read_lines(new_sub / fn)
        if bl == nl:
            continue
        diff = difflib.unified_diff(bl, nl, n=0)
        n_changed = sum(1 for l in diff if l.startswith(("+", "-")) and not l.startswith(("+++", "---")))
        base_types = {l.split()[1] for l in bl if l.startswith("type ")}
        new_types = {l.split()[1] for l in nl if l.startswith("type ")}
        added = new_types - base_types
        removed = base_types - new_types
        detail = []
        if added:
            detail.append(f"新增类型 {len(added)}：{', '.join(sorted(added)[:8])}{'…' if len(added) > 8 else ''}")
        if removed:
            detail.append(f"删除类型 {len(removed)}：{', '.join(sorted(removed)[:8])}{'…' if len(removed) > 8 else ''}")
        out.append(f"- `dto/{fn}`：{n_changed} 行变更" + (f"（{'；'.join(detail)}）" if detail else ""))
    return out


def safe_output_path(user_arg: str) -> Path | None:
    """--out 只允许写入当前工作目录内的相对/绝对路径，拒绝越界"""
    cwd = Path.cwd().resolve()
    candidate = Path(user_arg).resolve()
    return candidate if candidate.is_relative_to(cwd) else None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("base_tag")
    ap.add_argument("new_tag")
    ap.add_argument("--module", help="路由过滤关键字（如 firewall / terminal / files）")
    ap.add_argument("--out", help="输出 Markdown 文件（缺省打印到 stdout；限当前工作目录内）")
    args = ap.parse_args()

    base_dir = ensure_source(args.base_tag)
    new_dir = ensure_source(args.new_tag)
    module = args.module.lower() if args.module else None

    base_routes, new_routes = extract_routes(base_dir, new_dir)
    added = sorted(new_routes - base_routes)
    removed = sorted(base_routes - new_routes)
    if module:
        added = [r for r in added if module in r.lower()]
        removed = [r for r in removed if module in r.lower()]

    lines = [
        f"# 1Panel {args.base_tag} → {args.new_tag} API 变更报告",
        "",
        "> 由 scripts/upstream_api_diff.py 生成（源码源；路由层 + DTO 层）",
        "> 局限：同名路径但处理函数变化的端点不出现在对照里（如 v2.3.0 /firewall/port 改义），",
        "> 需人工对照 router 文件的 handler diff 复核",
        "",
        "## 端点新增",
    ]
    lines += [f"+ `{r}`" for r in added] or ["（无）"]
    lines += ["", "## 端点删除/改名"]
    lines += [f"- `{r}`" for r in removed] or ["（无）"]
    lines += ["", "## DTO 变更"]
    lines += dto_diff(base_dir, new_dir) or ["（无变更）"]

    report = "\n".join(lines) + "\n"
    if args.out:
        out_path = safe_output_path(args.out)
        if out_path is None:
            sys.exit("--out 仅允许写入当前工作目录内")
        out_path.write_text(report, encoding="utf-8")
        print(f"已写入 {out_path}", file=sys.stderr)
    else:
        sys.stdout.write(report)


if __name__ == "__main__":
    main()
