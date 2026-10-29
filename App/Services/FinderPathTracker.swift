import AppKit
import os

/// 采集访达当前打开的文件夹。
///
/// Finder Sync 的 targetedURL() 在 ad-hoc 签名下恒为 nil（扩展已因此移除），
/// 这里由宿主 App（非沙盒）通过 AppleScript 问访达要前台窗口路径。
final class FinderPathTracker {

    private let logger = Logger(subsystem: SharedPaths.logSubsystem, category: "finder-path")

    private var timer: Timer?
    private var lastPath: String?
    private var isRunning = false

    func start() {
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        // 只有访达在前台时才有「当前文件夹」语义，也避免无谓地跨进程查询
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        guard let path = frontWindowPath(), path != lastPath else { return }
        lastPath = path
        PathHistoryStore.shared.record(path: path)
        logger.notice("记录访达目录 \(path, privacy: .public)")
    }

    private func frontWindowPath() -> String? {
        let source = """
        tell application "Finder"
            if (count of windows) is 0 then return ""
            return POSIX path of (target of front window as alias)
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            logger.error("读取访达窗口失败: \(error.description, privacy: .public)")
            return nil
        }
        let path = result.stringValue ?? ""
        return path.isEmpty ? nil : path
    }
}
