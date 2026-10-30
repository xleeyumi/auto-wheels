#!/usr/bin/env bash
# =============================================================================
# 把本次触发的输入固化成 ci/requirements.txt
#
# 优先级：requirements_text（多行输入） > requirements_file（仓库内文件）
# 同时准备好 pip 缓存目录和 wheel 输出目录，供后续构建与缓存步骤使用。
# =============================================================================
set -euo pipefail

REQ_TEXT="${REQ_TEXT:-}"
REQ_FILE="${REQ_FILE:-requirements.txt}"
WORK_DIR="ci"

mkdir -p "$WORK_DIR/requirements" "$WORK_DIR/cache/pip" wheelhouse

if [ -n "${REQ_TEXT//[[:space:]]/}" ]; then
  echo "[input] 使用 workflow 输入中的 requirements 内容"
  # tr -d '\r'：避免 Windows 换行导致 pip 解析出 "numpy==1.26.4\r" 之类的脏依赖名
  printf '%s\n' "$REQ_TEXT" | tr -d '\r' > "$WORK_DIR/requirements.txt"
else
  echo "[input] 使用仓库文件：$REQ_FILE"
  if [ ! -f "$REQ_FILE" ]; then
    echo "::error::既没有提供 requirements_text，仓库里也找不到 $REQ_FILE"
    exit 1
  fi
  tr -d '\r' < "$REQ_FILE" > "$WORK_DIR/requirements.txt"
fi

# 去掉空行与纯注释行后必须仍有内容
if ! grep -qvE '^[[:space:]]*(#|$)' "$WORK_DIR/requirements.txt"; then
  echo "::error::requirements 内容为空，无法构建"
  exit 1
fi

echo "[input] 依赖清单条数：$(grep -cvE '^[[:space:]]*(#|$)' "$WORK_DIR/requirements.txt")"
echo "[input] 依赖清单内容："
sed -e 's/^/    /' "$WORK_DIR/requirements.txt"
