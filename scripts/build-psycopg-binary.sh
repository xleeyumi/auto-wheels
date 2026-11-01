#!/usr/bin/env bash
# =============================================================================
# 为没有官方 psycopg-binary wheel 的 ARMv7 构建兼容 wheel。
#
# 客户端的 requirements 可以继续写：
#   psycopg[binary]>=3.1
#
# 本脚本会：
#   1. 用目标解释器解析 requirements 中实际选中的 psycopg 版本；
#   2. 下载同版本 psycopg-c sdist（自带生成好的 C 文件）；
#   3. 按上游 copy_to_binary.py 的规则把 psycopg-c 改名为 psycopg-binary；
#   4. 编译 wheel，把 libpq 及非 glibc 动态库装进 psycopg_binary.libs；
#   5. 安装并导入 psycopg_binary.pq 做冒烟测试。
# =============================================================================
set -euo pipefail

REQUIREMENTS_FILE="${REQUIREMENTS_FILE:?REQUIREMENTS_FILE 不能为空}"
INTERPRETER="${INTERPRETER:?INTERPRETER 不能为空}"
RAW_DIR="${RAW_DIR:?RAW_DIR 不能为空}"
WORK_DIR="${WORK_DIR:-/tmp/wheelbuild}"
PIP_CACHE_DIR="${PIP_CACHE_DIR:-/tmp/pip-cache}"
PYTHON_VERSION="${PYTHON_VERSION:-unknown}"
PLATFORM_NAME="${PLATFORM_NAME:-unknown}"
AUTO_PSYCOPG_BINARY="${AUTO_PSYCOPG_BINARY:-false}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/psycopg_binary_helper.py"

log() { printf '\033[1;34m[psycopg-binary]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[psycopg-binary]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[psycopg-binary]\033[0m %s\n' "$*"; }

is_true() {
  case "$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes) return 0 ;;
    *) return 1 ;;
  esac
}

if ! is_true "$AUTO_PSYCOPG_BINARY"; then
  exit 0
fi

mkdir -p "$RAW_DIR" "$WORK_DIR" "$PIP_CACHE_DIR"
export PIP_CACHE_DIR

version="$("$INTERPRETER" "$HELPER" resolve-version --requirements "$REQUIREMENTS_FILE")" || exit $?
if [ -z "${version//[[:space:]]/}" ]; then
  log "requirements 中没有当前平台生效的 psycopg[binary]，跳过"
  exit 0
fi
version="$(echo "$version" | tail -n 1 | tr -d '[:space:]')"
log "[$PLATFORM_NAME / Python $PYTHON_VERSION] 需要构建 psycopg-binary $version"

existing="$(find "$RAW_DIR" -maxdepth 1 -type f -name "psycopg_binary-${version}-*.whl" -print -quit)"
if [ -n "$existing" ]; then
  log "已存在对应 wheel，跳过重复构建: $existing"
  exit 0
fi

work="$WORK_DIR/psycopg-binary-${version}-python-${PYTHON_VERSION}"
rm -rf -- "$work"
mkdir -p "$work"

source_tar="${PSYCOPG_SOURCE_TAR:-$work/psycopg-$version.tar.gz}"
if [ -n "${PSYCOPG_SOURCE_TAR:-}" ]; then
  if [ ! -f "$PSYCOPG_SOURCE_TAR" ]; then
    err "PSYCOPG_SOURCE_TAR 指向的文件不存在: $PSYCOPG_SOURCE_TAR"
    exit 1
  fi
  log "使用预置源码: $PSYCOPG_SOURCE_TAR"
else
  "$INTERPRETER" "$HELPER" download-source --version "$version" --output "$source_tar"
fi

source_dir="$work/psycopg-binary-src"
"$INTERPRETER" "$HELPER" prepare-source --source-tar "$source_tar" --output "$source_dir"

build_dir="$work/built"
bundle_dir="$work/bundled"
mkdir -p "$build_dir" "$bundle_dir"

log "从源码编译 psycopg-binary $version（PSYCOPG_IMPL=binary）"
if ! PSYCOPG_IMPL=binary "$INTERPRETER" -m pip wheel \
    --disable-pip-version-check --no-color --progress-bar off \
    --no-deps -w "$build_dir" "$source_dir"; then
  err "psycopg-binary $version 编译失败"
  exit 1
fi

built="$(find "$build_dir" -maxdepth 1 -type f -name "psycopg_binary-${version}-*.whl" -print -quit)"
if [ -z "$built" ]; then
  err "编译成功但没有找到 psycopg_binary-${version}-*.whl"
  exit 1
fi

bundled="$("$INTERPRETER" "$HELPER" bundle-wheel --wheel "$built" --output-dir "$bundle_dir")" || exit $?
bundled="$(echo "$bundled" | tail -n 1)"
if [ ! -f "$bundled" ]; then
  err "没有生成打包后的 wheel: $bundled"
  exit 1
fi
cp -f "$bundled" "$RAW_DIR/"
rm -f "$built"

# 在容器内真正安装并导入一次，确保 RPATH 和打包的 libpq 可用。
smoke_dir="$work/smoke"
log "冒烟测试 psycopg-binary $version"
if ! "$INTERPRETER" -m pip install -q --disable-pip-version-check --ignore-installed \
    --target "$smoke_dir" "psycopg==$version" "$bundled"; then
  err "冒烟测试安装失败"
  exit 1
fi
if ! PYTHONPATH="$smoke_dir" PSYCOPG_IMPL=binary "$INTERPRETER" - <<'PY'
import psycopg
from psycopg import pq

assert pq.__impl__ == "binary", pq.__impl__
assert pq.__build_version__ > 0, pq.__build_version__
print(f"psycopg={psycopg.__version__} pq_impl={pq.__impl__} libpq={pq.__build_version__}")
PY
then
  err "psycopg_binary.pq 导入失败"
  exit 1
fi

log "完成: $RAW_DIR/$(basename "$bundled")"
