#!/usr/bin/env python3
"""
swagger_api_diff.py —— 1Panel 两版 Swagger 文档对比（三源之法·Swagger 源）

用法:
    python3 scripts/swagger_api_diff.py archive/doc/1panel_api_doc.json \\
        logs/1panel_api_doc_v2.3.0.json [--module firewall] [--out report.md]

对比什么:
    1. 路径与方法级增删（paths × methods）
    2. 同路径同方法的契约变化：operationId 改义 / 请求·响应 schema $ref 变化
    3. 受影响 definition 的字段级 diff（properties 增删与类型变化）

定位与局限:
    - Swagger 依赖后端注解，存在覆盖缺口（如 v2.3.0 /hosts/firewall/port 无注解）：
      路由增删以 scripts/upstream_api_diff.py（源码 diff）为准，本脚本提供**字段级**补充
    - 与源码 diff 互补：本脚本能直接看到 request/response 的 DTO 引用与字段口径
"""

import argparse
import json
import sys
from pathlib import Path

HTTP_METHODS = {"get", "post", "put", "delete", "patch", "head", "options"}


def load_doc(path: str) -> dict:
    p = Path(path)
    if not p.is_file():
        sys.exit(f"文件不存在：{path}")
    return json.loads(p.read_text(encoding="utf-8"))


def schema_ref(params_or_responses) -> tuple[str, str]:
    """提取 (request $ref 末段, 成功响应 $ref 末段)"""
    req_ref = resp_ref = ""
    if isinstance(params_or_responses, dict):
        for param in params_or_responses.get("parameters", []) or []:
            if param.get("in") == "body":
                ref = param.get("schema", {}).get("$ref", "")
                req_ref = ref.rsplit("/", 1)[-1] if ref else ""
        responses = params_or_responses.get("responses", {}) or {}
        ok = responses.get("200") or responses.get("201") or {}
        ref = ok.get("schema", {}).get("$ref", "")
        resp_ref = ref.rsplit("/", 1)[-1] if ref else ""
    return req_ref, resp_ref


def collect_operations(doc: dict) -> dict:
    """path+method → {operationId, reqRef, respRef, annotated}"""
    ops = {}
    for path, methods in (doc.get("paths") or {}).items():
        if not isinstance(methods, dict):
            continue
        for method, detail in methods.items():
            if method not in HTTP_METHODS or not isinstance(detail, dict):
                continue
            req_ref, resp_ref = schema_ref(detail)
            ops[f"{method.upper()} {path}"] = {
                "operationId": detail.get("operationId", ""),
                "reqRef": req_ref,
                "respRef": resp_ref,
                # 空详情 = 路由存在但缺注解（覆盖率缺口标记）
                "annotated": bool(detail),
            }
    return ops


def definition_field_diff(base_doc: dict, new_doc: dict,
                          base_name: str, new_name: str) -> list[str]:
    def props(doc, name):
        d = (doc.get("definitions") or {}).get(name, {})
        return d.get("properties") or {}

    bp, np = props(base_doc, base_name), props(new_doc, new_name)
    lines = []
    added = set(np) - set(bp)
    removed = set(bp) - set(np)
    for f in sorted(added):
        lines.append(f"      + `{f}`: {np[f].get('type', np[f].get('$ref', '?'))}")
    for f in sorted(removed):
        lines.append(f"      - `{f}`: {bp[f].get('type', bp[f].get('$ref', '?'))}")
    for f in sorted(set(bp) & set(np)):
        t1 = bp[f].get("type") or bp[f].get("$ref", "")
        t2 = np[f].get("type") or np[f].get("$ref", "")
        if t1 != t2:
            lines.append(f"      ~ `{f}`: {t1} → {t2}")
    return lines


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("base_doc")
    ap.add_argument("new_doc")
    ap.add_argument("--module", help="路径过滤关键字（如 firewall / terminal / files）")
    ap.add_argument("--out", help="输出 Markdown 文件（缺省 stdout；限当前工作目录内）")
    args = ap.parse_args()

    base_doc = load_doc(args.base_doc)
    new_doc = load_doc(args.new_doc)
    base_ops = collect_operations(base_doc)
    new_ops = collect_operations(new_doc)

    module = args.module.lower() if args.module else None

    def keep(key: str) -> bool:
        return module in key.lower() if module else True

    added = sorted(k for k in new_ops.keys() - base_ops.keys() if keep(k))
    removed = sorted(k for k in base_ops.keys() - new_ops.keys() if keep(k))
    changed = []
    affected_defs: list[tuple[str, str]] = []
    for key in sorted(base_ops.keys() & new_ops.keys()):
        if not keep(key):
            continue
        b, n = base_ops[key], new_ops[key]
        diffs = []
        if b["operationId"] != n["operationId"]:
            diffs.append(f"operationId：{b['operationId'] or '—'} → {n['operationId'] or '—'}")
        if b["reqRef"] != n["reqRef"]:
            diffs.append(f"请求体：{b['reqRef'] or '—'} → {n['reqRef'] or '—'}")
            if b["reqRef"] or n["reqRef"]:
                affected_defs.append((b["reqRef"], n["reqRef"]))
        if b["respRef"] != n["respRef"]:
            diffs.append(f"响应：{b['respRef'] or '—'} → {n['respRef'] or '—'}")
            if b["respRef"] or n["respRef"]:
                affected_defs.append((b["respRef"], n["respRef"]))
        if diffs:
            changed.append((key, diffs))
        if not n["annotated"]:
            changed.append((key, ["⚠️ 路由存在但 Swagger 无注解（以源码 diff 为准）"]))

    lines = [
        f"# Swagger 对比报告：{args.base_doc} → {args.new_doc}",
        "",
        "> scripts/swagger_api_diff.py 生成（Swagger 源；字段级补充）",
        "> 局限①：Swagger 依赖后端注解且旧版注解不全——「端点新增」实为「真新增 ∪ 新补注解」，",
        "> 路由增删以 scripts/upstream_api_diff.py（源码 diff）为准；本脚本核心价值在",
        "> 「同路径契约变化」与「DTO 字段级 diff」两节（源码 diff 抓不到的口径变化）",
        f"> 基线 paths={len(base_ops)} / definitions={len(base_doc.get('definitions') or {})}；"
        f"新版 paths={len(new_ops)} / definitions={len(new_doc.get('definitions') or {})}",
        "",
        "## 端点新增",
    ]
    lines += [f"+ `{k}`" for k in added] or ["（无）"]
    lines += ["", "## 端点删除/改名"]
    new_path_keys = set(new_doc.get("paths") or {})
    if removed:
        for k in removed:
            path = k.split(" ", 1)[1]
            if path in new_path_keys:
                lines.append(f"- `{k}`（⚠️ 新版存在该路径但无方法注解——可能为注解缺口而非删除，以源码 diff 为准）")
            else:
                lines.append(f"- `{k}`")
    else:
        lines.append("（无）")
    lines += ["", "## 同路径契约变化（改义/注解缺口）"]
    if changed:
        for key, diffs in changed:
            lines.append(f"- `{key}`")
            lines += [f"  - {d}" for d in diffs]
    else:
        lines.append("（无）")

    lines += ["", "## 受影响 DTO 字段级 diff"]
    seen = set()
    emitted = False
    for b_name, n_name in affected_defs:
        pair_key = f"{b_name}→{n_name}"
        if pair_key in seen or (not b_name and not n_name):
            continue
        seen.add(pair_key)
        field_lines = definition_field_diff(base_doc, new_doc, b_name, n_name)
        if field_lines:
            emitted = True
            lines.append(f"- `{b_name or '（新）'}` → `{n_name or '（删）'}`")
            lines += field_lines
    if not emitted:
        lines.append("（无字段级变化或引用未变）")

    report = "\n".join(lines) + "\n"
    if args.out:
        cwd = Path.cwd().resolve()
        out_path = Path(args.out).resolve()
        if not out_path.is_relative_to(cwd):
            sys.exit("--out 仅允许写入当前工作目录内")
        out_path.write_text(report, encoding="utf-8")
        print(f"已写入 {out_path}", file=sys.stderr)
    else:
        sys.stdout.write(report)


if __name__ == "__main__":
    main()
