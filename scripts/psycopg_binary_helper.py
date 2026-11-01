#!/usr/bin/env python3
"""Helpers for building a psycopg-binary wheel on ARMv7.

This mirrors the rename performed by upstream psycopg's
``tools/ci/copy_to_binary.py`` and adds a small self-contained wheel bundler
for platforms where auditwheel has no usable policy.
"""

from __future__ import annotations

import argparse
import configparser
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path
from typing import Iterator

try:
    from packaging.requirements import InvalidRequirement, Requirement
    from packaging.utils import canonicalize_name
    from packaging.version import Version
except ImportError:  # pip vendors packaging; use it before the build env is prepared
    from pip._vendor.packaging.requirements import InvalidRequirement, Requirement
    from pip._vendor.packaging.utils import canonicalize_name
    from pip._vendor.packaging.version import Version

PYPI_JSON_URL = "https://pypi.org/pypi/psycopg-c/{version}/json"

TEXT_SUFFIXES = {
    ".c",
    ".cfg",
    ".in",
    ".md",
    ".py",
    ".pxd",
    ".pyx",
    ".rst",
    ".toml",
    ".txt",
}

SYSTEM_LIBRARY_PATTERNS = (
    re.compile(r"^linux-vdso"),
    re.compile(r"^ld-linux"),
    re.compile(r"^ld64"),
    re.compile(r"^libpython"),
    re.compile(r"^libc\.so"),
    re.compile(r"^libm\.so"),
    re.compile(r"^libdl\.so"),
    re.compile(r"^libpthread\.so"),
    re.compile(r"^librt\.so"),
    re.compile(r"^libutil\.so"),
    re.compile(r"^libresolv\.so"),
    re.compile(r"^libnsl\.so"),
    re.compile(r"^libcrypt\.so"),
    re.compile(r"^libgcc_s\.so"),
    re.compile(r"^libstdc\+\+\.so"),
    re.compile(r"^libatomic\.so"),
    re.compile(r"^libgomp\.so"),
)


def log(message: str) -> None:
    print(f"[psycopg-binary] {message}", file=sys.stderr)


def fail(message: str) -> "None":
    log(f"错误: {message}")
    raise SystemExit(1)


def logical_requirement_lines(path: Path, seen: set[Path] | None = None) -> Iterator[str]:
    """Yield requirement lines, including simple -r/-c includes."""
    seen = set() if seen is None else seen
    resolved = path.resolve()
    if resolved in seen:
        return
    seen.add(resolved)

    pending = ""
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = pending + raw.strip()
        pending = ""
        if line.endswith("\\"):
            pending = line[:-1] + " "
            continue
        if not line:
            continue

        stripped = line.strip()
        if stripped.startswith("-"):
            match = re.match(r"^(?:-r|--requirement|-c|--constraint)\s+(.+)$", stripped)
            if match:
                nested = Path(match.group(1).strip().strip("'\""))
                if not nested.is_absolute():
                    nested = path.parent / nested
                if nested.is_file():
                    yield from logical_requirement_lines(nested, seen)
            continue

        # A hash option is not part of a PEP 508 requirement.
        line = re.sub(r"\s+--hash(?:=|\s+)\S+", "", line)
        # Only whitespace-prefixed '#' starts a requirement comment.
        line = re.sub(r"\s+#.*$", "", line).strip()
        if line:
            yield line

    if pending.strip():
        yield pending.strip()


def resolve_psycopg_version(requirements: Path) -> None:
    active: list[str] = []
    has_binary = False

    for line in logical_requirement_lines(requirements):
        try:
            req = Requirement(line)
        except InvalidRequirement as exc:
            if "psycopg" in line.lower():
                fail(f"无法解析 psycopg 依赖行 {line!r}: {exc}")
            continue

        if canonicalize_name(req.name) != "psycopg":
            continue
        if req.marker is not None and not req.marker.evaluate():
            continue

        active.append(line)
        if "binary" in {extra.lower() for extra in req.extras}:
            has_binary = True

    if not has_binary:
        return

    if not active:
        fail("找到了 psycopg[binary]，但没有可用的 psycopg 约束")

    with tempfile.TemporaryDirectory(prefix="psycopg-resolve-") as tmp:
        tmpdir = Path(tmp)
        req_file = tmpdir / "requirements.txt"
        report_file = tmpdir / "report.json"
        req_file.write_text("\n".join(active) + "\n", encoding="utf-8")

        cmd = [
            sys.executable,
            "-m",
            "pip",
            "install",
            "--disable-pip-version-check",
            "--no-color",
            "--dry-run",
            "--ignore-installed",
            "--no-deps",
            "--report",
            str(report_file),
            "-r",
            str(req_file),
        ]
        log(f"解析 psycopg 版本: {'; '.join(active)}")
        proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if proc.returncode != 0:
            if proc.stdout:
                print(proc.stdout, file=sys.stderr)
            fail("pip 无法解析 psycopg 版本")

        data = json.loads(report_file.read_text(encoding="utf-8"))
        versions: list[str] = []
        for item in data.get("install", []):
            metadata = item.get("metadata") or {}
            if canonicalize_name(metadata.get("name", "")) == "psycopg":
                version = metadata.get("version")
                if version:
                    versions.append(str(version))

        if not versions:
            fail("pip 报告里没有找到已解析的 psycopg 版本")
        # pip normally reports one psycopg; keep the highest if it ever reports more.
        versions.sort(key=Version, reverse=True)
        print(versions[0])


def _download_file(url: str, output: Path, expected_sha256: str | None = None) -> None:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "auto-wheels/1.0", "Accept-Encoding": "identity"},
    )
    last_error: Exception | None = None
    for attempt in range(1, 4):
        temp_name = ""
        try:
            log(f"下载源码 ({attempt}/3): {url}")
            with urllib.request.urlopen(request, timeout=90) as response:
                with tempfile.NamedTemporaryFile(
                    prefix="psycopg-sdist-", suffix=".tmp", dir=output.parent, delete=False
                ) as fh:
                    shutil.copyfileobj(response, fh)
                    temp_name = fh.name
            if not temp_name or os.path.getsize(temp_name) == 0:
                raise RuntimeError("下载文件为空")
            if expected_sha256 and _sha256(Path(temp_name)) != expected_sha256:
                raise RuntimeError("下载文件的 SHA-256 不匹配")
            os.replace(temp_name, output)
            return
        except Exception as exc:
            last_error = exc
            if temp_name:
                try:
                    os.unlink(temp_name)
                except OSError:
                    pass
    fail(f"下载 psycopg 源码失败: {last_error}")


def download_source(version: str, output: Path) -> None:
    """Download the psycopg-c sdist, which already contains generated C files."""
    json_url = PYPI_JSON_URL.format(version=version)
    request = urllib.request.Request(
        json_url,
        headers={"User-Agent": "auto-wheels/1.0", "Accept-Encoding": "identity"},
    )
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            data = json.load(response)
    except Exception as exc:
        fail(f"无法读取 psycopg-c=={version} 的 PyPI 元数据: {exc}")

    sdists = [item for item in data.get("urls", []) if item.get("packagetype") == "sdist"]
    if not sdists:
        fail(f"psycopg-c=={version} 在 PyPI 上没有 sdist")
    sdists.sort(key=lambda item: 0 if str(item.get("filename", "")).endswith(".tar.gz") else 1)
    url = sdists[0].get("url")
    if not url:
        fail(f"psycopg-c=={version} 的 sdist 缺少下载地址")

    output.parent.mkdir(parents=True, exist_ok=True)
    log(f"下载 psycopg-c {version} sdist")
    expected = (sdists[0].get("digests") or {}).get("sha256")
    _download_file(str(url), output, expected)


def safe_extract(tar_path: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve()
    with tarfile.open(tar_path, "r:*") as archive:
        for member in archive.getmembers():
            if member.issym() or member.islnk() or member.isdev():
                continue
            target = (destination / member.name).resolve()
            try:
                common = os.path.commonpath([str(root), str(target)])
            except ValueError:
                common = ""
            if common != str(root):
                fail(f"源码归档包含越界路径: {member.name}")

            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    fail(f"无法读取源码归档文件: {member.name}")
                with source, open(target, "wb") as out:
                    shutil.copyfileobj(source, out)


def _drop_source_only_package_data(text: str, section: str) -> str:
    """Remove the psycopg_c package-data block before renaming it.

    psycopg-c and psycopg-binary sdists contain both keys; renaming the former
    without dropping it would create a duplicate key in setup.cfg/pyproject.toml.
    """
    lines = text.splitlines(keepends=True)
    in_section = False
    index = 0
    while index < len(lines):
        stripped = lines[index].strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            in_section = stripped == section
            index += 1
            continue
        if in_section and re.match(r"^psycopg_c\s*=", lines[index]):
            end = index + 1
            while end < len(lines):
                candidate = lines[end]
                stripped_candidate = candidate.strip()
                if (
                    candidate[:1].isspace()
                    or not stripped_candidate
                    or stripped_candidate.startswith("]")
                ):
                    end += 1
                    continue
                break
            del lines[index:end]
            break
        index += 1
    return "".join(lines)


def _dedupe_setup_cfg(path: Path) -> None:
    """Merge duplicate package_data keys created by the psycopg_c rename."""
    text = path.read_text(encoding="utf-8")
    in_package_data = False
    occurrences = 0
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            in_package_data = stripped == "[options.package_data]"
            continue
        if in_package_data and re.match(r"^psycopg_binary\s*=", line):
            occurrences += 1
    if occurrences <= 1:
        return

    parser = configparser.RawConfigParser(strict=False)
    parser.optionxform = str
    parser.read_string(text)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        parser.write(fh)
    log(f"合并 setup.cfg 中重复的 psycopg_binary 配置项: {occurrences} -> 1")


def _replace_text_files(root: Path) -> None:
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        data = path.read_bytes()
        new = data
        if path.name == "setup.cfg":
            new = _drop_source_only_package_data(
                new.decode("utf-8"), "[options.package_data]"
            ).encode("utf-8")
        elif path.name == "pyproject.toml":
            new = _drop_source_only_package_data(
                new.decode("utf-8"), "[tool.setuptools.package-data]"
            ).encode("utf-8")
        new = new.replace(b"psycopg_c", b"psycopg_binary")
        new = new.replace(b"psycopg-c", b"psycopg-binary")
        if path.name in {"pq.pyx", "pq.c"}:
            new = re.sub(rb"(__impl__\s*=\s*)['\"]c['\"]", rb"\1'binary'", new)
        if path.name == "pq.c":
            # The sdist ships Cython-generated C. Its module init interns the
            # implementation name, so patch the real assignment as well. The
            # expression shape differs between Cython 3.0 and 3.1+.
            impl_re = re.compile(
                rb"PyDict_SetItem\(\s*"
                rb"(?P<dict>__pyx(?:_mstate_global->__pyx)?_d)\s*,\s*"
                rb"(?P<key>__pyx(?:_mstate_global->__pyx)?_n_[su]_impl)\s*,\s*"
                rb"(?P<value>__pyx(?:_mstate_global->__pyx)?_n_u_c)\s*\)"
            )

            def replace_impl(match: re.Match[bytes]) -> bytes:
                return (
                    b"PyDict_SetItem("
                    + match.group("dict")
                    + b", "
                    + match.group("key")
                    + b', PyUnicode_FromString("binary"))'
                )

            new = impl_re.sub(replace_impl, new)
        if new != data:
            path.write_bytes(new)


def prepare_source(source_tar: Path, output: Path) -> None:
    if output.exists() and any(output.iterdir()):
        fail(f"输出目录非空: {output}")
    output.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="psycopg-source-") as tmp:
        extracted = Path(tmp) / "src"
        safe_extract(source_tar, extracted)

        candidates = [
            path
            for path in extracted.rglob("*")
            if path.is_dir()
            and (path.name.startswith("psycopg_c-") or path.name.startswith("psycopg-c-"))
            and (path / "psycopg_c").is_dir()
            and ((path / "pyproject.toml").is_file() or (path / "setup.py").is_file())
        ]
        if not candidates:
            # Fallback for a Git checkout or an archive that extracts directly.
            candidates = [
                path
                for path in extracted.rglob("psycopg_c")
                if path.is_dir()
                and (path / "psycopg_c").is_dir()
                and ((path / "pyproject.toml").is_file() or (path / "setup.py").is_file())
            ]
        if not candidates and (extracted / "psycopg_c").is_dir():
            candidates = [extracted]
        if len(candidates) != 1:
            fail(f"源码树里应有且仅有一个 psycopg-c 源码目录，实际找到 {len(candidates)} 个")
        shutil.copytree(candidates[0], output, dirs_exist_ok=True)

    package = output / "psycopg_binary"
    if (output / "psycopg_c").is_dir():
        (output / "psycopg_c").rename(package)
    if not package.is_dir():
        fail("改名后找不到 psycopg_binary 包目录")

    readme_binary = output / "README-binary.rst"
    if readme_binary.is_file():
        os.replace(readme_binary, output / "README.rst")

    _replace_text_files(output)
    setup_cfg = output / "setup.cfg"
    if setup_cfg.is_file():
        _dedupe_setup_cfg(setup_cfg)

    for name in ("pyproject.toml", "setup.cfg", "setup.py"):
        path = output / name
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8")
        if "psycopg_c" in text or "psycopg-c" in text:
            fail(f"{name} 仍残留 psycopg_c / psycopg-c 名称")

    pyx = package / "pq.pyx"
    if pyx.is_file() and not re.search(r"__impl__\s*=\s*['\"]binary['\"]", pyx.read_text(encoding="utf-8")):
        fail("pq.pyx 的 __impl__ 没有改成 binary")
    c_source = package / "pq.c"
    if c_source.is_file() and b'PyUnicode_FromString("binary")' not in c_source.read_bytes():
        fail("pq.c 的 __impl__ 没有改成 binary")

    log(f"已生成 psycopg-binary 源码树: {output}")


def _parse_ldd(path: Path) -> dict[str, Path]:
    proc = subprocess.run(["ldd", str(path)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if proc.returncode != 0:
        fail(f"ldd 失败: {path}\n{proc.stdout}")
    if "not found" in proc.stdout:
        fail(f"存在未解析的动态库: {path}\n{proc.stdout}")

    deps: dict[str, Path] = {}
    for line in proc.stdout.splitlines():
        match = re.match(r"\s*(\S+)\s+=>\s+(/\S+)\s+\(", line)
        if match:
            deps[match.group(1)] = Path(match.group(2)).resolve()
            continue
        # Static executables may print just an absolute interpreter/library path.
        stripped = line.strip()
        if stripped.startswith("/") and " (" in stripped:
            candidate = Path(stripped.split(" (", 1)[0])
            deps[candidate.name] = candidate.resolve()
    return deps


def _should_bundle(name: str) -> bool:
    lower = name.lower()
    return not any(pattern.search(lower) for pattern in SYSTEM_LIBRARY_PATTERNS)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def bundle_wheel(wheel: Path, output_dir: Path) -> None:
    for tool in ("patchelf", "ldd"):
        if shutil.which(tool) is None:
            fail(f"缺少工具 {tool}（ARMv7 平台应安装 patchelf）")

    output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="psycopg-bundle-") as tmp:
        root = Path(tmp) / "wheel"
        root.mkdir()
        with zipfile.ZipFile(wheel) as archive:
            archive.extractall(root)

        metadata_files = list(root.glob("*.dist-info/METADATA"))
        if len(metadata_files) != 1:
            fail(f"wheel 里应有且仅有一个 METADATA，实际找到 {len(metadata_files)} 个")
        metadata_name = None
        for line in metadata_files[0].read_text(encoding="utf-8").splitlines():
            if line.lower().startswith("name:"):
                metadata_name = line.split(":", 1)[1].strip()
                break
        if canonicalize_name(metadata_name or "") != "psycopg-binary":
            fail(f"wheel 的 Name 不是 psycopg-binary: {metadata_name!r}")

        modules = [path for path in (root / "psycopg_binary").rglob("*.so") if path.is_file()]
        if not modules:
            fail("wheel 里没有找到 psycopg_binary 的 .so 文件")

        queue = list(modules)
        seen: set[Path] = set()
        dependencies: dict[str, Path] = {}
        while queue:
            current = queue.pop(0).resolve()
            if current in seen:
                continue
            seen.add(current)
            for name, path in _parse_ldd(current).items():
                if not _should_bundle(name):
                    continue
                if not path.is_file():
                    fail(f"动态库不存在: {name} -> {path}")
                previous = dependencies.get(name)
                if previous is not None and _sha256(previous) != _sha256(path):
                    fail(f"动态库重名但内容不同: {name}: {previous} / {path}")
                dependencies[name] = path
                queue.append(path)

        libs_dir = root / "psycopg_binary.libs"
        libs_dir.mkdir(exist_ok=True)
        for name, source in sorted(dependencies.items()):
            target = libs_dir / name
            shutil.copy2(source, target)
            subprocess.run(["patchelf", "--set-rpath", "$ORIGIN", str(target)], check=True)

        if not any(path.name.startswith("libpq") for path in libs_dir.iterdir()):
            fail("没有把 libpq 打进 psycopg_binary.libs")

        for module in modules:
            subprocess.run(
                ["patchelf", "--set-rpath", "$ORIGIN/../psycopg_binary.libs", str(module)],
                check=True,
            )

        libs_root = libs_dir.resolve()
        for path in modules + list(libs_dir.iterdir()):
            for name, resolved in _parse_ldd(path).items():
                if _should_bundle(name) and resolved.parent != libs_root:
                    fail(f"{path.name} 的动态库没有从 wheel 内部解析: {name} -> {resolved}")

        packed_dir = Path(tmp) / "packed"
        packed_dir.mkdir()
        subprocess.run(
            [sys.executable, "-m", "wheel", "pack", str(root), "--dest-dir", str(packed_dir)],
            check=True,
        )
        wheels = list(packed_dir.glob("*.whl"))
        if len(wheels) != 1:
            fail(f"重新打包 wheel 失败，产出数量: {len(wheels)}")
        target = output_dir / wheels[0].name
        os.replace(wheels[0], target)
        log(f"已打包 {len(dependencies)} 个动态库: {target}")
        print(target)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    resolve = sub.add_parser("resolve-version", help="解析 requirements 中实际选中的 psycopg 版本")
    resolve.add_argument("--requirements", required=True, type=Path)

    download = sub.add_parser("download-source", help="下载 psycopg-c sdist 源码包")
    download.add_argument("--version", required=True)
    download.add_argument("--output", required=True, type=Path)

    prepare = sub.add_parser("prepare-source", help="把 psycopg-c 源码改名为 psycopg-binary")
    prepare.add_argument("--source-tar", required=True, type=Path)
    prepare.add_argument("--output", required=True, type=Path)

    bundle = sub.add_parser("bundle-wheel", help="把 libpq 依赖打进 wheel")
    bundle.add_argument("--wheel", required=True, type=Path)
    bundle.add_argument("--output-dir", required=True, type=Path)

    args = parser.parse_args()
    if args.command == "resolve-version":
        resolve_psycopg_version(args.requirements)
    elif args.command == "download-source":
        download_source(args.version, args.output)
    elif args.command == "prepare-source":
        prepare_source(args.source_tar, args.output)
    elif args.command == "bundle-wheel":
        bundle_wheel(args.wheel, args.output_dir)


if __name__ == "__main__":
    main()
