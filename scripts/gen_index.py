#!/usr/bin/env python3
"""生成 wheel 仓库索引（发布到 GitHub Pages 使用）

产出：
  <site>/wheels/index.html        平铺文件列表 —— 客户端 --find-links 的目标
  <site>/simple/<pkg>/index.html  PEP 503 简单索引 —— 客户端 --index-url 的目标
  <site>/index.html               站点首页，带使用说明与平台覆盖统计

之所以要自己生成索引：GitHub Pages 不做目录列表，pip 用
--find-links 时需要页面里存在指向 .whl 的 <a href>。
"""

from __future__ import annotations

import argparse
import hashlib
import html
import re
from collections import defaultdict
from pathlib import Path

# {name}-{version}(-{build})?-{python}-{abi}-{platform}.whl
WHEEL_RE = re.compile(
    r"^(?P<name>[^-]+)-(?P<version>[^-]+)(?:-(?P<build>[^-]+))?"
    r"-(?P<py>[^-]+)-(?P<abi>[^-]+)-(?P<platform>[^-]+)\.whl$"
)

# 平台标签 → 设备说明，仅用于首页展示
PLATFORM_HINTS = {
    "manylinux_2_17_x86_64": "x86_64 / glibc≥2.17",
    "manylinux_2_28_x86_64": "x86_64 / glibc≥2.28",
    "manylinux_2_17_aarch64": "ARM64 / glibc≥2.17（树莓派 64 位、Jetson）",
    "manylinux_2_28_aarch64": "ARM64 / glibc≥2.28（Debian 12、Ubuntu 24.04）",
    "linux_armv7l": "ARMv7 / glibc（树莓派 32 位）",
    "musllinux_1_2_x86_64": "x86_64 / musl≥1.2（Alpine）",
    "musllinux_1_2_aarch64": "ARM64 / musl≥1.2（Alpine）",
    "musllinux_1_2_armv7l": "ARMv7 / musl≥1.2（Alpine 32 位）",
}

STYLE = """
:root { color-scheme: light dark; }
body { font-family: -apple-system, "Segoe UI", "Microsoft YaHei", sans-serif;
       max-width: 980px; margin: 2rem auto; padding: 0 1rem; line-height: 1.6; }
h1 { font-size: 1.5rem; border-bottom: 1px solid #8884; padding-bottom: .4rem; }
table { border-collapse: collapse; width: 100%; font-size: .9rem; }
th, td { border-bottom: 1px solid #8884; padding: .35rem .5rem; text-align: left;
         vertical-align: top; }
code, pre { font-family: ui-monospace, Consolas, monospace; }
pre { background: #8881; padding: .8rem 1rem; border-radius: 6px; overflow-x: auto; }
tr:target { background: #ffd54f44; }
"""


def normalize(name: str) -> str:
    """PEP 503 项目名归一化。"""
    return re.sub(r"[-_.]+", "-", name).lower()


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_wheel(path: Path) -> dict[str, str] | None:
    match = WHEEL_RE.match(path.name)
    if not match:
        return None
    info = match.groupdict()
    info["filename"] = path.name
    info["project"] = normalize(info["name"])
    info["size"] = human_size(path.stat().st_size)
    return info


def human_size(size: int) -> str:
    value = float(size)
    for unit in ("B", "KB", "MB", "GB"):
        if value < 1024 or unit == "GB":
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} GB"


def page(title: str, body: str, root: str) -> str:
    return (
        "<!DOCTYPE html>\n"
        '<html lang="zh-CN">\n<head>\n'
        '<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        f"<title>{html.escape(title)}</title>\n"
        f"<style>{STYLE}</style>\n"
        "</head>\n<body>\n"
        f"{body}\n<hr><p><a href=\"{root}\">← 返回首页</a></p>\n"
        "</body>\n</html>\n"
    )


def write_find_links(site: Path, wheels: list[Path]) -> None:
    """pip install --find-links <.../wheels/>"""
    rows = [
        f'<tr><td><a href="{html.escape(w.name)}">{html.escape(w.name)}</a></td>'
        f"<td>{human_size(w.stat().st_size)}</td></tr>"
        for w in wheels
    ]
    body = [
        "<h1>Wheel 文件列表（find-links）</h1>",
        f"<p>共 {len(wheels)} 个 wheel。客户端命令：</p>",
        "<pre>pip install --find-links &lt;本页地址&gt; --prefer-binary -r requirements.txt</pre>",
        "<table><thead><tr><th>文件</th><th>大小</th></tr></thead><tbody>",
        *rows,
        "</tbody></table>",
    ]
    out = site / "wheels" / "index.html"
    out.write_text(page("Wheel 文件列表", "\n".join(body), "../"), encoding="utf-8")


def write_simple_index(site: Path, wheels: list[Path]) -> None:
    """PEP 503：pip install --index-url <.../simple/>"""
    by_project: dict[str, list[dict[str, str]]] = defaultdict(list)
    for wheel in wheels:
        info = parse_wheel(wheel)
        if info:
            by_project[info["project"]].append(info)

    simple_dir = site / "simple"
    simple_dir.mkdir(parents=True, exist_ok=True)

    for project, entries in sorted(by_project.items()):
        links = []
        for info in sorted(entries, key=lambda i: i["filename"]):
            digest = sha256_of(site / "wheels" / info["filename"])
            links.append(
                f'<a href="../../wheels/{html.escape(info["filename"])}'
                f'#sha256={digest}">{html.escape(info["filename"])}</a><br>'
            )
        body = f"<h1>{html.escape(project)}</h1>\n" + "\n".join(links)
        project_dir = simple_dir / project
        project_dir.mkdir(parents=True, exist_ok=True)
        (project_dir / "index.html").write_text(
            page(project, body, "../../"), encoding="utf-8"
        )

    items = "\n".join(
        f'<li><a href="{html.escape(p)}/">{html.escape(p)}</a></li>'
        for p in sorted(by_project)
    )
    body = (
        "<h1>简单索引（PEP 503）</h1>\n"
        f"<ul>{items}</ul>"
    )
    (simple_dir / "index.html").write_text(page("Simple Index", body, "../"), encoding="utf-8")


def write_home(site: Path, wheels: list[Path], site_url: str, title: str) -> None:
    stats: dict[str, int] = defaultdict(int)
    projects: set[str] = set()
    total_size = 0
    for wheel in wheels:
        info = parse_wheel(wheel)
        total_size += wheel.stat().st_size
        if not info:
            stats["其它"] += 1
            continue
        stats[info["platform"]] += 1
        projects.add(info["project"])

    rows = [
        f"<tr><td><code>{html.escape(tag)}</code></td>"
        f"<td>{html.escape(PLATFORM_HINTS.get(tag, '—'))}</td>"
        f"<td>{count}</td></tr>"
        for tag, count in sorted(stats.items())
    ]

    body = f"""
<h1>{html.escape(title)}</h1>
<p>共 <strong>{len(wheels)}</strong> 个 wheel、<strong>{len(projects)}</strong> 个项目、
<strong>{human_size(total_size)}</strong>。</p>

<h2>客户端安装</h2>
<pre>pip install --find-links {html.escape(site_url)}/wheels/ --prefer-binary -r requirements.txt</pre>
<p>完全离线（不访问 PyPI）：</p>
<pre>pip install --no-index --find-links {html.escape(site_url)}/wheels/ -r requirements.txt</pre>
<p>长期生效可写入 <code>~/.pip/pip.conf</code>（Windows：<code>%APPDATA%\\pip\\pip.ini</code>）：</p>
<pre>[global]
find-links = {html.escape(site_url)}/wheels/
prefer-binary = true</pre>
<p>也可以当作 PEP 503 索引使用：</p>
<pre>pip install --index-url {html.escape(site_url)}/simple/ --trusted-host {html.escape(site_url.split("//")[-1].split("/")[0])}</pre>

<h2>平台覆盖</h2>
<table><thead><tr><th>wheel 平台标签</th><th>适用设备</th><th>数量</th></tr></thead>
<tbody>{''.join(rows)}</tbody></table>

<p><a href="wheels/">→ 浏览全部 wheel 文件</a></p>
"""
    (site / "index.html").write_text(page(title, body, "./"), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description="生成 wheel 仓库索引")
    parser.add_argument("--site", required=True, help="GitHub Pages 站点根目录")
    parser.add_argument("--site-url", default="", help="站点地址，用于首页示例命令")
    parser.add_argument("--title", default="Python Wheelhouse", help="站点标题")
    args = parser.parse_args()

    site = Path(args.site)
    wheels_dir = site / "wheels"
    wheels_dir.mkdir(parents=True, exist_ok=True)
    wheels = sorted(wheels_dir.glob("*.whl"))

    write_find_links(site, wheels)
    write_simple_index(site, wheels)
    write_home(site, wheels, args.site_url.rstrip("/"), args.title)

    print(f"[index] 站点目录 : {site}")
    print(f"[index] wheel 数量: {len(wheels)}")
    print(f"[index] 入口      : {args.site_url}/wheels/")


if __name__ == "__main__":
    main()
