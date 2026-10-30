#!/bin/bash
# 一键发布：建 GitHub 仓库 → 推源码 → 建 Pre-release 并上传 zip
# 用法：./script/publish_release.sh
# 依赖：GitHub CLI（gh）已登录。安装：brew install gh，登录：gh auth login
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${REPO:-zhr3350/RecentFolder}"
VERSION="0.1.0-beta.1"
TAG="v$VERSION"
ZIP="dist/RecentFolder-$VERSION.zip"
DESC="macOS 菜单栏小工具：把访达最近打开的文件夹贴到保存对话框下方，点一下就跳过去。"

command -v gh >/dev/null 2>&1 \
  || { echo "缺少 gh。先执行：brew install gh && gh auth login"; exit 1; }
gh auth status >/dev/null 2>&1 \
  || { echo "gh 未登录。先执行：gh auth login"; exit 1; }

if [ ! -f "$ZIP" ]; then
  echo "缺少 $ZIP。先构建：CONFIG=Release ./script/build_and_run.sh --verify"
  echo "然后打包：ditto -c -k --sequesterRsrc --keepParent ~/Applications/RecentFolder.app \"$ZIP\""
  exit 1
fi

# 1. 建仓库（已存在就跳过）。不加 README，避免和本地已有的提交历史打架
if gh repo view "$REPO" >/dev/null 2>&1; then
  echo "==> 仓库已存在：$REPO"
else
  echo "==> 创建仓库 $REPO"
  gh repo create "$REPO" --public --description "$DESC"
fi

# 2. 推源码
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "https://github.com/$REPO.git"
else
  git remote add origin "https://github.com/$REPO.git"
fi
echo "==> 推送 main"
git push -u origin main

# 3. 建预发布版，把 zip 作为 Release 资产上传
NOTES=$(cat <<'EOF'
首个 Beta 版，功能可用但接口与行为仍可能调整。

## 安装
1. 下载下方 `RecentFolder-0.1.0-beta.1.zip`，解压
2. 把 `RecentFolder.app` 拖进「应用程序」
3. **右键点击图标 →「打开」**。本版本没有 Apple 公证，双击会被 Gatekeeper 拦下
4. 首次运行会请求「辅助功能」权限，用于在保存对话框里自动定位

## 已知限制
- 未做 Developer ID 签名与公证，未签名的 Beta 不保证跨机器一致行为
- 依赖访达前台窗口，访达完全关闭时不产生新记录

## 系统要求
macOS 14 及以上
EOF
)

echo "==> 创建预发布版 $TAG"
gh release create "$TAG" "$ZIP" \
  --repo "$REPO" \
  --title "RecentFolder $VERSION (Beta)" \
  --prerelease \
  --notes "$NOTES"

echo "==> 完成：https://github.com/$REPO/releases/tag/$TAG"
