#!/usr/bin/env bash
# =============================================================================
# 宿主机侧调度脚本：按 Python 版本逐个启动「目标架构容器」构建 wheel
#
# 之所以一个容器只跑一个 Python 版本：
#   * manylinux/musllinux 镜像里每个 /opt/python/cpXX-cpXX 是独立解释器；
#   * arm32v7/python 这类镜像的镜像名里就带版本（{py} 占位符）；
#   * 单个版本失败时不会带崩其它版本。
#
# 环境变量：
#   IMAGE            镜像名，可含 {py} 占位符
#   DOCKER_PLATFORM  docker --platform，例如 linux/arm64
#   INTERPRETER      解释器路径模板，可含 {cptag} / {py}
#   REPAIR           auditwheel | none
#   SYS_PKGS         追加安装的系统包（yum/dnf/apt/apk 名）
#   PYTHON_VERSIONS  逗号分隔，例如 3.9,3.10,3.11,3.12
#   EXTRA_PIP_ARGS   追加给 pip wheel 的参数
#   IGNORE_BUILD_ERRORS  true 时单个依赖构建失败不阻塞
#   STRICT_REPAIR    true 时 auditwheel 修复失败即报错
#   PLATFORM_NAME    仅用于日志
#   AUTO_PSYCOPG_BINARY  true 时在 ARMv7 上自动构建 psycopg-binary
# =============================================================================
set -uo pipefail

IMAGE="${IMAGE:?IMAGE 不能为空}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"
# 注意：默认值里含花括号的变量不能用 ${VAR:-{...}}，bash 会在第一个 } 处截断
if [ -z "${INTERPRETER:-}" ]; then
  INTERPRETER='/opt/python/{cptag}-{cptag}/bin/python'
fi
REPAIR="${REPAIR:-auditwheel}"
# 触发时可覆盖平台默认的修复策略：auto=按 platforms.json，auditwheel=强制修复
REPAIR_OVERRIDE="${REPAIR_OVERRIDE:-auto}"
if [ "$REPAIR_OVERRIDE" != "auto" ] && [ -n "$REPAIR_OVERRIDE" ]; then
  REPAIR="$REPAIR_OVERRIDE"
fi
SYS_PKGS="${SYS_PKGS:-}"
PYTHON_VERSIONS="${PYTHON_VERSIONS:?PYTHON_VERSIONS 不能为空}"
EXTRA_PIP_ARGS="${EXTRA_PIP_ARGS:-}"
IGNORE_BUILD_ERRORS="${IGNORE_BUILD_ERRORS:-true}"
STRICT_REPAIR="${STRICT_REPAIR:-false}"
PLATFORM_NAME="${PLATFORM_NAME:-$DOCKER_PLATFORM}"
AUTO_PSYCOPG_BINARY="${AUTO_PSYCOPG_BINARY:-false}"

JOBS="$(nproc 2>/dev/null || echo 2)"

# 把逗号/空格混合的版本列表拆成数组
read -r -a VERSIONS <<< "$(echo "$PYTHON_VERSIONS" | tr ',' ' ')"

echo "::group::构建配置"
echo "平台        : $PLATFORM_NAME"
echo "镜像        : $IMAGE"
echo "docker 架构 : $DOCKER_PLATFORM"
echo "Python 版本 : ${VERSIONS[*]}"
echo "修复工具    : $REPAIR"
echo "系统依赖    : ${SYS_PKGS:-<无>}"
echo "psycopg 兼容: ${AUTO_PSYCOPG_BINARY}"
echo "pip 参数    : ${EXTRA_PIP_ARGS:-<无>}"
echo "并行度      : $JOBS"
echo "::endgroup::"

OK=()
FAILED=()

# 空数组安全拼接（兼容 bash 4.2 的 set -u）
join() {
  if [ $# -eq 0 ]; then echo "<无>"; else echo "$*"; fi
}

for py in "${VERSIONS[@]}"; do
  [ -z "$py" ] && continue
  cptag="cp${py//./}"
  image="${IMAGE//\{py\}/$py}"
  interp="${INTERPRETER//\{cptag\}/$cptag}"
  interp="${interp//\{py\}/$py}"
  failures_file="/io/ci/build-failures-${PLATFORM_NAME//[^a-zA-Z0-9._-]/_}-${py}.txt"

  echo "::group::[$PLATFORM_NAME] Python $py → $image"

  docker run --rm \
    --platform "$DOCKER_PLATFORM" \
    -v "$PWD:/io" \
    -w /io \
    -e REQUIREMENTS_FILE=/io/ci/requirements.txt \
    -e OUT_DIR=/io/wheelhouse \
    -e INTERPRETER="$interp" \
    -e PYTHON_VERSION="$py" \
    -e REPAIR="$REPAIR" \
    -e SYS_PKGS="$SYS_PKGS" \
    -e EXTRA_PIP_ARGS="$EXTRA_PIP_ARGS" \
    -e IGNORE_BUILD_ERRORS="$IGNORE_BUILD_ERRORS" \
    -e STRICT_REPAIR="$STRICT_REPAIR" \
    -e AUTO_PSYCOPG_BINARY="$AUTO_PSYCOPG_BINARY" \
    -e PIP_CACHE_DIR=/io/ci/cache/pip \
    -e WORK_DIR=/tmp/wheelbuild \
    -e FAILURES_FILE="$failures_file" \
    -e MAKEFLAGS="-j${JOBS}" \
    -e CMAKE_BUILD_PARALLEL_LEVEL="$JOBS" \
    "$image" bash /io/scripts/build-wheels.sh
  rc=$?

  if [ $rc -eq 0 ]; then
    OK+=("$py")
  else
    FAILED+=("$py")
    echo "::warning::[$PLATFORM_NAME] Python $py 构建未完全成功（退出码 $rc）"
  fi
  echo "::endgroup::"
done

echo "::group::[$PLATFORM_NAME] 构建结果"
echo "成功: $(join ${OK[@]+"${OK[@]}"})"
echo "失败: $(join ${FAILED[@]+"${FAILED[@]}"})"
ls -lh wheelhouse 2>/dev/null | tail -n +2 | awk '{print $5, $9}' | sed -e 's/^/    /' || true
echo "::endgroup::"

if [ ${#FAILED[@]} -gt 0 ]; then
  echo "::error::[$PLATFORM_NAME] 以下 Python 版本构建失败: ${FAILED[*]}"
  exit 1
fi
exit 0
