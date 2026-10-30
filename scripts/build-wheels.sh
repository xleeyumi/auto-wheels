#!/usr/bin/env bash
# =============================================================================
# 容器内构建脚本：为「当前镜像所代表的目标架构」构建 wheel
#
# 由 scripts/run-build.sh 在目标架构容器中调用，也可以在 manylinux/musllinux
# 镜像里手工执行：
#   docker run --rm -v "$PWD:/io" -w /io \
#     -e REQUIREMENTS_FILE=/io/requirements.txt \
#     quay.io/pypa/manylinux2014_aarch64 bash /io/scripts/build-wheels.sh
#
# 环境变量：
#   REQUIREMENTS_FILE   依赖清单路径
#   OUT_DIR             最终 wheel 输出目录
#   INTERPRETER         目标 Python 解释器（已展开 {cptag}）
#   PYTHON_VERSION      形如 3.11，仅用于日志/失败清单命名
#   REPAIR              auditwheel | none
#   SYS_PKGS            需要额外安装的系统包（yum/dnf/apt/apk 包名）
#   EXTRA_PIP_ARGS      追加给 pip wheel 的参数
#   IGNORE_BUILD_ERRORS 1 时单个依赖构建失败不阻塞整体
#   STRICT_REPAIR       1 时 auditwheel 修复失败即报错
#   FAILURES_FILE       构建失败的依赖会写到这里
#   PIP_CACHE_DIR       pip 下载缓存目录（可挂载复用）
# =============================================================================
set -o pipefail

REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-/io/ci/requirements.txt}"
OUT_DIR="${OUT_DIR:-/io/wheelhouse}"
INTERPRETER="${INTERPRETER:-python3}"
PYTHON_VERSION="${PYTHON_VERSION:-unknown}"
REPAIR="${REPAIR:-auditwheel}"
SYS_PKGS="${SYS_PKGS:-}"
EXTRA_PIP_ARGS="${EXTRA_PIP_ARGS:-}"
IGNORE_BUILD_ERRORS="${IGNORE_BUILD_ERRORS:-true}"
STRICT_REPAIR="${STRICT_REPAIR:-false}"
FAILURES_FILE="${FAILURES_FILE:-/io/ci/build-failures.txt}"
PIP_CACHE_DIR="${PIP_CACHE_DIR:-/tmp/pip-cache}"
WORK_DIR="${WORK_DIR:-/tmp/wheelbuild}"

RAW_DIR="$WORK_DIR/raw"
LOG_DIR="$WORK_DIR/logs"
FAILED_PKGS=()
WARN_MSGS=()

log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m  %s\n' "$*"; WARN_MSGS+=("$*"); }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*"; }

# 布尔型环境变量判断（兼容 true/1/yes 多种写法）
is_true() {
  case "$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 1. 系统依赖（编译某些包需要 libxml2-devel / libffi-devel 等）
# ---------------------------------------------------------------------------
install_sys_pkgs() {
  local pkgs="${SYS_PKGS//,/ }"
  [ -z "${pkgs//[[:space:]]/}" ] && return 0

  log "安装系统依赖: $pkgs"
  if command -v yum >/dev/null 2>&1; then
    yum install -y --setopt=tsflags=nodocs --setopt=skip_missing_names_on_install=False $pkgs
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y $pkgs
  elif command -v microdnf >/dev/null 2>&1; then
    microdnf install -y $pkgs
  elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq --no-install-recommends $pkgs
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache $pkgs
  else
    warn "镜像里没有可识别的包管理器，跳过系统依赖安装"
    return 0
  fi
}

# ---------------------------------------------------------------------------
# 2. 准备解释器与缓存目录
# ---------------------------------------------------------------------------
prepare_python() {
  if [ ! -x "$INTERPRETER" ]; then
    err "找不到 Python 解释器: $INTERPRETER"
    err "当前镜像可用的解释器："
    ls -d /opt/python/cp3*/bin/python 2>/dev/null || true
    exit 1
  fi
  log "Python: $("$INTERPRETER" -V 2>&1) → $INTERPRETER"
  export PIP_CACHE_DIR
  mkdir -p "$RAW_DIR" "$LOG_DIR" "$OUT_DIR" "$PIP_CACHE_DIR" || true

  # 老镜像自带 pip 版本过旧，可能读不懂较新的 sdist 元数据
  if ! "$INTERPRETER" -m pip install -q -U pip >"$LOG_DIR/pip-upgrade.log" 2>&1; then
    warn "pip 升级失败（继续使用自带版本），详见 $LOG_DIR/pip-upgrade.log"
  fi
}

# ---------------------------------------------------------------------------
# 3. 构建 wheel
# ---------------------------------------------------------------------------
pip_wheel_args() {
  PIP_ARGS=(-m pip wheel --disable-pip-version-check --no-color --progress-bar off -w "$RAW_DIR")
  # 用户追加参数按空格拆分
  read -r -a _extra <<< "$EXTRA_PIP_ARGS"
  PIP_ARGS+=(${_extra[@]+"${_extra[@]}"})
}

build_from_requirements() {
  log "解析依赖并构建: $REQUIREMENTS_FILE"
  if "$INTERPRETER" "${PIP_ARGS[@]}" -r "$REQUIREMENTS_FILE" 2>&1 | tee "$LOG_DIR/pip-wheel.log"; then
    return 0
  fi
  return 1
}

# 整份清单构建失败时，逐行重试，尽量把能建的都建出来
build_line_by_line() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    # 去掉注释与首尾空白，跳过空行和 pip 选项行（-r/--index-url 等）
    line="${line%%#*}"
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    case "$line" in -*) continue ;; esac

    log "单独构建: $line"
    if ! "$INTERPRETER" "${PIP_ARGS[@]}" "$line" 2>&1 | tee -a "$LOG_DIR/pip-wheel.log"; then
      err "构建失败: $line"
      FAILED_PKGS+=("$line")
    fi
  done < "$REQUIREMENTS_FILE"
}

# ---------------------------------------------------------------------------
# 4. 修复 wheel 标签（auditwheel / musllinux）
# ---------------------------------------------------------------------------
AUDITWHEEL=()
detect_auditwheel() {
  if command -v auditwheel >/dev/null 2>&1; then
    AUDITWHEEL=(auditwheel); return 0
  fi
  if [ -x /opt/_internal/tools/bin/auditwheel ]; then
    AUDITWHEEL=(/opt/_internal/tools/bin/auditwheel); return 0
  fi
  if "$INTERPRETER" -m auditwheel --version >/dev/null 2>&1; then
    AUDITWHEEL=("$INTERPRETER" -m auditwheel); return 0
  fi
  if "$INTERPRETER" -m pip install -q auditwheel >/dev/null 2>&1; then
    AUDITWHEEL=("$INTERPRETER" -m auditwheel); return 0
  fi
  return 1
}

repair_all() {
  local whl base
  if [ "$REPAIR" != "auditwheel" ]; then
    log "跳过修复（REPAIR=$REPAIR），直接保留原始平台标签"
    for whl in "$RAW_DIR"/*.whl; do
      [ -e "$whl" ] || continue
      cp -f "$whl" "$OUT_DIR/"
    done
    return 0
  fi

  if ! detect_auditwheel; then
    err "镜像里没有 auditwheel，无法把 wheel 修成 manylinux/musllinux 标签"
    if is_true "$STRICT_REPAIR"; then return 1; fi
    warn "按宽松模式继续：wheel 将保留 linux_* 原始标签"
    cp -f "$RAW_DIR"/*.whl "$OUT_DIR/" 2>/dev/null
    return 0
  fi

  for whl in "$RAW_DIR"/*.whl; do
    [ -e "$whl" ] || continue
    base="$(basename "$whl")"
    case "$base" in
      *-none-any.whl)
        cp -f "$whl" "$OUT_DIR/" ;;
      *manylinux*|*musllinux*)
        # 直接下载到的官方 wheel，无需修复
        cp -f "$whl" "$OUT_DIR/" ;;
      *)
        if "${AUDITWHEEL[@]}" repair -w "$OUT_DIR" "$whl" >>"$LOG_DIR/auditwheel.log" 2>&1; then
          log "已修复: $base"
        else
          err "auditwheel 修复失败: $base"
          FAILED_PKGS+=("repair:$base")
          if is_true "$STRICT_REPAIR"; then
            return 1
          fi
          warn "保留未修复的 wheel: $base（目标设备与本镜像 glibc 兼容时可安装）"
          cp -f "$whl" "$OUT_DIR/"
        fi
        ;;
    esac
  done
  return 0
}

# ---------------------------------------------------------------------------
# 5. 结果汇总
# ---------------------------------------------------------------------------
summary() {
  local count
  count=$(ls -1 "$OUT_DIR"/*.whl 2>/dev/null | wc -l | tr -d ' ')
  log "输出目录: $OUT_DIR（$count 个 wheel）"
  ls -1 "$OUT_DIR"/*.whl 2>/dev/null | sed -e 's#.*/#    #' || true

  if [ ${#WARN_MSGS[@]} -gt 0 ]; then
    echo "### ⚠️ Python $PYTHON_VERSION 构建告警" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    for msg in "${WARN_MSGS[@]}"; do
      echo "- $msg" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    done
  fi

  if [ ${#FAILED_PKGS[@]} -gt 0 ]; then
    mkdir -p "$(dirname "$FAILURES_FILE")"
    {
      echo "# Python $PYTHON_VERSION 构建失败项"
      printf '%s\n' "${FAILED_PKGS[@]}"
    } >> "$FAILURES_FILE"
    echo "### ❌ Python $PYTHON_VERSION 构建失败" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    for pkg in "${FAILED_PKGS[@]}"; do
      echo "- \`$pkg\`" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    done
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
install_sys_pkgs
prepare_python
pip_wheel_args

if ! build_from_requirements; then
  if is_true "$IGNORE_BUILD_ERRORS"; then
    warn "依赖整体解析构建失败，改为逐行重试（单项失败不影响其它依赖）"
    build_line_by_line
  else
    err "依赖构建失败（IGNORE_BUILD_ERRORS=$IGNORE_BUILD_ERRORS），终止"
    FAILED_PKGS+=("requirements.txt（整体解析构建失败）")
    summary || true
    exit 1
  fi
fi

repair_ok=1
repair_all || repair_ok=0

summary
rc=$?

if [ $repair_ok -eq 0 ]; then
  err "wheel 修复阶段失败（STRICT_REPAIR=$STRICT_REPAIR）"
  exit 1
fi
if [ $rc -ne 0 ] && ! is_true "$IGNORE_BUILD_ERRORS"; then
  err "存在构建失败项，任务判定为失败"
  exit 1
fi
exit 0
