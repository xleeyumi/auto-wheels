#!/usr/bin/env bash
# =============================================================================
# 把 wheel 归档到 GitHub Release（作为备份下载通道）
#
# 注意：Release 页面的附件是分页展示的（每页 10 个），不适合直接给 pip 的
# --find-links 使用。给 pip 用的索引请走 GitHub Pages。
#
# 环境变量：
#   GH_TOKEN      具有 contents:write 权限的 token
#   RELEASE_TAG   Release 标签，默认 wheels
# =============================================================================
set -euo pipefail

GH_TOKEN="${GH_TOKEN:?GH_TOKEN 不能为空}"
RELEASE_TAG="${RELEASE_TAG:-wheels}"

WHEELS=(wheelhouse/*.whl)
if [ ! -e "${WHEELS[0]}" ]; then
  echo "::warning::没有可归档的 wheel，跳过 Release 发布"
  exit 0
fi

export GH_TOKEN
if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  echo "[release] 向已有 Release $RELEASE_TAG 追加 ${#WHEELS[@]} 个 wheel"
  gh release upload "$RELEASE_TAG" "${WHEELS[@]}" --clobber
else
  echo "[release] 创建 Release $RELEASE_TAG"
  gh release create "$RELEASE_TAG" "${WHEELS[@]}" \
    --title "Python Wheels" \
    --notes "由 GitHub Actions 自动构建的 wheel 集合。

- 构建时间：$(date -u '+%Y-%m-%d %H:%M:%S UTC')
- wheel 数量：${#WHEELS[@]}
- 给 pip 使用的索引（推荐）：见仓库 GitHub Pages 的 \`/wheels/\` 目录

> Release 附件分页展示，仅适合人工下载，不适合 \`pip --find-links\`。"
fi

echo "[release] 完成：$RELEASE_TAG"
