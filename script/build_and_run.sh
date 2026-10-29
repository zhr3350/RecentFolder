#!/bin/bash
# 一键构建 + 签名 + 启动 RecentFolder
# 用法：./script/build_and_run.sh [--logs] [--verify]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-Debug}"
DD="build/DerivedData"
BUILT="$DD/Build/Products/$CONFIG/RecentFolder.app"

mkdir -p "$DD"

echo "==> 构建 ($CONFIG)"
xcodebuild -project RecentFolder.xcodeproj -scheme RecentFolder \
  -configuration "$CONFIG" -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO build > "$DD/build.log" 2>&1 \
  || { grep -E "error:" "$DD/build.log" | head -20; exit 1; }
echo "    构建成功"

# 先复制到 ~/Applications 再签名。
# 工程目录在 iCloud 同步的「文稿」里，构建产物会被反复打上 com.apple.FinderInfo，
# xattr -cr 清掉后立刻又被写回，codesign 必然报 "detritus not allowed"。
# ~/Applications 不受 iCloud 管理，xattr 清得干净，签名才能成功。
# Finder 扩展本身也只从 ~/Applications 或 /Applications 加载。
INSTALL="$HOME/Applications/RecentFolder.app"
APPEX="$INSTALL/Contents/PlugIns/RecentFolderFinder.appex"

# 构建目录里那份 App 之前被手动启动过也会留在后台，统一按 bundle 路径前缀全部清掉，
# 否则会出现多个菜单栏图标
pkill -f "RecentFolder.app/Contents/MacOS/RecentFolder" 2>/dev/null || true
echo "==> 复制到 $INSTALL"
rm -rf "$INSTALL"
mkdir -p "$HOME/Applications"
ditto --noextattr --norsrc "$BUILT" "$INSTALL"
xattr -cr "$INSTALL"

echo "==> 签名"
# ad-hoc 签名每次构建 cdhash 都会变，辅助功能授权会因此失效、要反复点开关。
# 优先用本机已有的开发者证书，签名身份稳定，TCC 授权可以一直复用。
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="-"
  echo "    未找到开发者证书，回退到 ad-hoc（重建后需要重新授权辅助功能）"
else
  echo "    使用身份：$SIGN_ID"
fi

codesign --force --sign "$SIGN_ID" --timestamp=none \
  --entitlements FinderExtension/FinderExtension.entitlements "$APPEX"
codesign --force --sign "$SIGN_ID" --timestamp=none \
  --entitlements App/RecentFolder.entitlements "$INSTALL"
codesign --verify --deep --strict "$INSTALL" && echo "    签名校验通过"

echo "==> 注册 Finder 扩展"
pluginkit -a "$INSTALL/Contents/PlugIns/RecentFolderFinder.appex" 2>/dev/null || true
pluginkit -e use -i com.haoran.recentfolder.finder 2>/dev/null || true

if [ "${1:-}" = "--verify" ]; then
  echo "==> 校验完成，未启动"
  exit 0
fi

echo "==> 启动"
pkill -f "$INSTALL/Contents/MacOS/RecentFolder" 2>/dev/null || true
sleep 1
open "$INSTALL"

if [ "${1:-}" = "--logs" ]; then
  log stream --predicate 'subsystem == "com.haoran.recentfolder"' --level debug
fi
