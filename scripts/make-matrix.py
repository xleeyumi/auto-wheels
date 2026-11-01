#!/usr/bin/env python3
"""校验 workflow 输入并生成构建矩阵。

输入（环境变量）：
  PLATFORMS        逗号/空格分隔的目标平台名，必须是 platforms.json 中的 key
  PYTHON_VERSIONS  逗号/空格分隔的 Python 版本，例如 "3.11,3.12"

输出（写入 $GITHUB_OUTPUT）：
  matrix     给 actions 的 strategy.matrix 用的 JSON
  platforms  归一化后的平台列表（逗号分隔）
  pythons    归一化后的 Python 版本列表（逗号分隔）
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

DEFAULT_ENTRY = {
    "image": "",
    "docker_platform": "linux/amd64",
    "qemu": "",
    "interpreter": "/opt/python/{cptag}/bin/python",
    "repair": "auditwheel",
    "sys_pkgs": "",
    "runs_on": "ubuntu-latest",
    "description": "",
    "psycopg_binary": False,
}

PY_RE = re.compile(r"^3\.(\d{1,2})$")


def split_list(raw: str) -> list[str]:
    """把逗号/空格/换行混杂的输入拆成列表，并去重保序。"""
    items = [x.strip() for x in re.split(r"[,;\s]+", raw or "") if x.strip()]
    seen: list[str] = []
    for item in items:
        if item not in seen:
            seen.append(item)
    return seen


def fail(message: str) -> None:
    print(f"::error::{message}")
    sys.exit(1)


def main() -> None:
    catalog_path = Path("platforms.json")
    if not catalog_path.is_file():
        fail("找不到 platforms.json")
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))

    platforms = split_list(os.environ.get("PLATFORMS", ""))
    if not platforms:
        fail("platforms 不能为空")
    unknown = [p for p in platforms if p not in catalog]
    if unknown:
        fail(f"未知平台 {unknown}，可选值：{', '.join(sorted(catalog))}")

    pythons = split_list(os.environ.get("PYTHON_VERSIONS", ""))
    if not pythons:
        fail("python_versions 不能为空")
    bad = [v for v in pythons if not PY_RE.match(v)]
    if bad:
        fail(f"Python 版本格式错误 {bad}，应形如 3.11")

    include = []
    for name in platforms:
        entry = {**DEFAULT_ENTRY, **catalog[name]}
        entry["name"] = name
        entry.setdefault("description", "")
        include.append(entry)

    matrix = {"include": include}
    outputs = {
        "matrix": json.dumps(matrix, ensure_ascii=False),
        "platforms": ",".join(platforms),
        "pythons": ",".join(pythons),
        # 缓存 key 不允许逗号，这里预先拼成 3.9-3.10-3.11 形式
        "cache_versions": "-".join(pythons),
    }

    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as fh:
        for key, value in outputs.items():
            fh.write(f"{key}<<__EOF__\n{value}\n__EOF__\n")

    # 便于在 Actions 页面上直接确认本次构建目标
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        lines = [
            "## 本次构建目标",
            "",
            "| 平台 | 目标架构 | 镜像 | wheel 标签 |",
            "| --- | --- | --- | --- |",
        ]
        for entry in include:
            lines.append(
                f"| `{entry['name']}` | {entry['docker_platform']} | "
                f"`{entry['image']}` | {entry['description']} |"
            )
        lines += ["", f"**Python 版本**：`{', '.join(pythons)}`", ""]
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")

    print(json.dumps(matrix, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
