#!/usr/bin/env bash
# =============================================================================
# 手动初始化 gh-pages 分支（可选）
#
# GitHub Pages 的 "Deploy from a branch" 只允许选择**已存在**的分支，而 gh-pages
# 要等 workflow 第一次发布成功才会被创建。如果希望「先把 Pages 配好、再跑构建」，
# 用本脚本建一个只含占位页的分支。
#
#   bash scripts/init-pages-branch.sh
#
# 实现上用临时 index + commit-tree 直接生成一个根提交再推送，
# **不会切换分支、不会改动工作区、不会提交你的项目文件**。
# =============================================================================
set -euo pipefail

BRANCH="${PAGES_BRANCH:-gh-pages}"
REMOTE_NAME="${PAGES_REMOTE_NAME:-origin}"

# 必须在 git 仓库里执行
GIT_DIR_ABS="$(git rev-parse --absolute-git-dir)"
cd "$(git rev-parse --show-toplevel)"

if git ls-remote --exit-code --heads "$REMOTE_NAME" "$BRANCH" >/dev/null 2>&1; then
  echo "[init] 远端已存在 $BRANCH 分支，无需初始化"
  exit 0
fi
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "[init] 本地已存在 $BRANCH 分支，直接推送"
  git push -u "$REMOTE_NAME" "$BRANCH"
  exit 0
fi

echo "[init] 为 $BRANCH 生成占位首页"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>Wheelhouse</title>
</head>
<body>
<h1>Wheelhouse</h1>
<p>索引尚未生成：运行一次 <code>Build Wheels</code> workflow 后访问 <code>/wheels/</code>。</p>
</body>
</html>
HTML
touch "$TMP_DIR/.nojekyll"

# 用独立的临时 index 构造提交，完全隔离于当前仓库工作区
(
  export GIT_DIR="$GIT_DIR_ABS"
  export GIT_WORK_TREE="$TMP_DIR"
  export GIT_INDEX_FILE="$TMP_DIR/.git-index"
  cd "$TMP_DIR"
  git add index.html .nojekyll
  tree="$(git write-tree)"
  commit="$(git -c user.name="github-actions[bot]" \
                -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
                commit-tree "$tree" -m "init: 初始化 gh-pages 占位页")"
  echo "[init] 提交 $(echo "$commit" | cut -c1-8)，推送为 $BRANCH"
  git push "$REMOTE_NAME" "$commit:refs/heads/$BRANCH"
)

echo "[init] 完成：远端分支 $BRANCH 已创建"
echo "[init] 下一步：Settings → Pages → Deploy from a branch → $BRANCH → / (root)"
