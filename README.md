# RecentFolder

macOS 菜单栏小工具：记住你在访达里打开过的文件夹，等你下次保存文件时，把最近 3 个目录浮在保存面板正下方，点一下就跳过去。

> 当前为 **Beta（预发布版）**，接口与行为仍可能变化。

## 它解决什么

保存文件时，macOS 的保存面板总是停在「上次用的位置」，而不是你此刻正在整理的那个项目文件夹。
RecentFolder 会记录你最近在访达里待过的目录，并在保存面板弹出时把它们贴在手边。

## 功能

- 自动记录访达当前文件夹（AppleScript 读取前台窗口路径，兼容部分第三方文件管理器）
- 保存对话框弹出时，在面板正下方浮出最近 3 个文件夹候选，点击后跳转
- 菜单栏面板：最近目录 / 常用目录（可置顶）、复制路径、在访达中显示
- 未授权辅助功能时会给出明确提示，不会静默失效

## 系统要求

- macOS 14 及以上

## 安装（Beta）

1. 从 [Releases](../../releases) 下载 `RecentFolder-x.y.z-beta.N.zip`
2. 解压后把 `RecentFolder.app` 拖进「应用程序」
3. 首次启动请右键点击图标 →「打开」。这个版本没有做 Apple 公证，直接双击会被 Gatekeeper 拦下
4. 首次运行会请求 **辅助功能** 权限，用于在保存对话框里自动定位

安装后它只常驻菜单栏，不显示 Dock 图标。

## 从源码构建

```bash
ruby script/generate_project.rb   # 生成 RecentFolder.xcodeproj
./script/build_and_run.sh         # 构建 → 安装到 ~/Applications → 签名 → 启动
```

需要 Xcode 命令行工具。`script/build_and_run.sh` 会优先使用本机已有的 Apple Development 证书签名，
以便辅助功能授权在重装后继续有效；没有证书时回退到 ad-hoc 签名。

应用图标（`App/Resources/AppIcon.icns`）是二进制资源，不随仓库分发，缺失时构建会使用系统默认图标。

## 已知限制

- 未做 Developer ID 签名与公证，其他机器首次打开需要右键「打开」
- 记录依赖访达的前台窗口，访达完全关闭时不会产生新记录

## 版本

`0.1.0-beta.1`
