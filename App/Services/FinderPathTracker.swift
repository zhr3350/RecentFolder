import AppKit
import os

/// 采集"用户当前正在看的文件夹"。
///
/// Finder Sync 的 targetedURL() 在 ad-hoc 签名下恒为 nil（扩展已因此移除），
/// 所以改成事件驱动，不再无脑轮询：
/// - 切到文件管理器的那一刻记录一次；
/// - 停留在文件管理器里时，0.5 秒一拍，但访达先用窗口标题判断"目录可能变了"，
///   标题没变就完全跳过，只有真的换了目录才跑一次 AppleScript；
/// - 三方管理器用 AX 通用探测（窗口 AXDocument → 路径样式的文本框 → 窗口标题）。
final class FinderPathTracker {

    /// 认识的文件管理器。表里没有的 App 不去猜，避免把 IDE、终端里
    /// 看起来像路径的文字当成"最近文件夹"。
    private static let fileManagers: [String: String] = [
        "com.apple.finder": "访达",
        "com.binarynights.ForkLift": "ForkLift",
        "com.cocoatech.PathFinder": "Path Finder",
        "com.macpaw.CommanderOne": "Commander One",
    ]

    private let logger = Logger(subsystem: SharedPaths.logSubsystem, category: "finder-path")

    private var timer: Timer?
    private var lastPath: String?
    /// 访达窗口标题，用作"目录变了没"的廉价信号
    private var lastSignal: String?
    private var isBusy = false

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh(force: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // 启动时前台可能已经是文件管理器
        refresh(force: true)
    }

    /// 切 App 时立刻看一眼，别等下一拍
    @objc private func activeAppChanged(_ note: Notification) {
        refresh(force: true)
    }

    private func refresh(force: Bool) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              let name = Self.fileManagers[bundleID] else { return }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let raw: String?
        if bundleID == "com.apple.finder" {
            let title = WindowPathProbe.title(of: app.processIdentifier) ?? ""
            if !force, title == lastSignal { return }
            lastSignal = title
            raw = finderFrontWindowPath()
        } else {
            raw = WindowPathProbe.path(of: app.processIdentifier)
        }

        // 脚本接口给的路径带尾斜杠，不统一的话同一个目录会被记成两条
        guard let raw, !raw.isEmpty else { return }
        let path = (raw as NSString).standardizingPath
        guard path != lastPath else { return }
        lastPath = path
        PathHistoryStore.shared.record(path: path)
        logger.notice("记录 \(name, privacy: .public) 的目录 \(path, privacy: .public)")
    }

    /// 访达不支持 AXDocument，也没有可靠的 AX 路径控件，只能问脚本接口。
    /// 只在目录真变了的时候调用，一次约 30~100ms。
    private func finderFrontWindowPath() -> String? {
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
