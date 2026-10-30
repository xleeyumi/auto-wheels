#!/usr/bin/env bash
# =============================================================================
# 把本次构建出的 wheel 增量发布到 GitHub Pages（gh-pages 分支）
#
# 环境变量：
#   GH_TOKEN       具有 contents:write 权限的 token
#   PAGES_BRANCH   分支名，默认 gh-pages
#   SITE_TITLE     首页标题
#   SITE_URL       站点地址（可选，默认按 GitHub Pages 规则推导）
#
# 生产环境前置条件：仓库 Settings → Pages → Source 选择
#   "Deploy from a branch" → gh-pages → / (root)
# =============================================================================
set -euo pipefail

GH_TOKEN="${GH_TOKEN:?GH_TOKEN 不能为空}"
PAGES_BRANCH="${PAGES_BRANCH:-gh-pages}"
SITE_TITLE="${SITE_TITLE:-Python Wheelhouse}"
ENABLE_PAGES="${ENABLE_PAGES:-1}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY 不能为空}"
SERVER="${GITHUB_SERVER_URL:-https://github.com}"
HOST="${SERVER#*//}"
HOST="${HOST%%/}"
OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

# GitHub Pages 项目站点地址推导
if [ -z "${SITE_URL:-}" ]; then
  if [ "$(echo "$NAME" | tr '[:upper:]' '[:lower:]')" = "$(echo "$OWNER" | tr '[:upper:]' '[:lower:]').github.io" ]; then
    SITE_URL="https://${OWNER,,}.github.io"
  else
    SITE_URL="https://${OWNER,,}.github.io/${NAME}"
  fi
fi

WHEELS=(wheelhouse/*.whl)
if [ ! -e "${WHEELS[0]}" ]; then
  echo "::warning::没有可发布的 wheel，跳过 Pages 发布"
  exit 0
fi
echo "[pages] 待发布 wheel: ${#WHEELS[@]} 个"

SITE_DIR=".pages-worktree"
# 允许通过 PAGES_REMOTE 覆盖推送地址（自建 git 服务 / 本地联调）
REMOTE="${PAGES_REMOTE:-https://x-access-token:${GH_TOKEN}@${HOST}/${REPO}.git}"
rm -rf "$SITE_DIR"

# 分支已存在则浅克隆，否则初始化一个孤儿分支
if git ls-remote --exit-code --heads "$REMOTE" "$PAGES_BRANCH" >/dev/null 2>&1; then
  echo "[pages] 拉取已有分支 $PAGES_BRANCH"
  git clone --quiet --depth 1 --branch "$PAGES_BRANCH" "$REMOTE" "$SITE_DIR"
else
  echo "[pages] 分支 $PAGES_BRANCH 不存在，创建孤儿分支"
  mkdir -p "$SITE_DIR"
  git -C "$SITE_DIR" init --quiet
  git -C "$SITE_DIR" remote add origin "$REMOTE"
  git -C "$SITE_DIR" checkout --quiet --orphan "$PAGES_BRANCH"
fi

mkdir -p "$SITE_DIR/wheels"
cp -f wheelhouse/*.whl "$SITE_DIR/wheels/"
touch "$SITE_DIR/.nojekyll"   # 关闭 Jekyll，避免下划线文件名/大文件被处理

python3 scripts/gen_index.py --site "$SITE_DIR" --site-url "$SITE_URL" --title "$SITE_TITLE"

git -C "$SITE_DIR" add -A
if git -C "$SITE_DIR" diff --cached --quiet; then
  echo "[pages] 内容没有变化，无需推送"
  exit 0
fi

git -C "$SITE_DIR" -c user.name="github-actions[bot]" \
  -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit --quiet -m "chore(wheelhouse): 更新 $(date -u '+%Y-%m-%d %H:%M:%S UTC')（${#WHEELS[@]} 个 wheel）"

git -C "$SITE_DIR" push --quiet origin "HEAD:refs/heads/${PAGES_BRANCH}"
echo "[pages] 已推送，索引地址：${SITE_URL}/wheels/"

# 首次运行尝试自动开启 Pages（需要仓库管理权限，失败不阻塞）
if [ "$ENABLE_PAGES" != "0" ]; then
  if command -v gh >/dev/null 2>&1; then
    gh api -X POST "repos/${REPO}/pages" \
      -f "source[branch]=${PAGES_BRANCH}" -f "source[path]=/" >/dev/null 2>&1 \
      || gh api -X PUT "repos/${REPO}/pages" \
        -f "source[branch]=${PAGES_BRANCH}" -f "source[path]=/" >/dev/null 2>&1 \
      || echo "::notice::自动开启 Pages 失败（可能权限不足），请到 Settings → Pages 手动选择 $PAGES_BRANCH 分支"
  fi
fi

rm -rf "$SITE_DIR"
