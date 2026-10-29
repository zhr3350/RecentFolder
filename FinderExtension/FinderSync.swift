import Cocoa
import FinderSync
import os

/// Finder 侧采集器：轮询当前目标目录，变化时写入共享历史
final class FinderSync: FIFinderSync {

    private let logger = Logger(subsystem: SharedPaths.logSubsystem, category: "finder-sync")
    private var pollTimer: Timer?
    private var lastRecordedPath: String?
    private var lastLoggedPath: String?
    private var pollCount = 0

    override init() {
        super.init()
        // 骨架阶段先覆盖整个磁盘，后续可改为用户配置的关注目录
        let home = FileManager.default.homeDirectoryForCurrentUser
        let monitored = ["/", home.path,
                         home.appendingPathComponent("Desktop").path,
                         home.appendingPathComponent("Documents").path,
                         home.appendingPathComponent("Downloads").path]
            .map { URL(fileURLWithPath: $0) }
        FIFinderSyncController.default().directoryURLs = Set(monitored)
        let actual = FIFinderSyncController.default().directoryURLs
            .map(\.path).sorted().joined(separator: ", ")
        startPolling()
        logger.notice("FinderSync 初始化，监视=\(actual, privacy: .public)，共享目录=\(SharedPaths.sharedDirectory().path, privacy: .public)")
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - 轮询当前目录

    private func startPolling() {
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.captureTargetedFolder()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// 访达当前窗口的目录发生变化时记录一次
    private func captureTargetedFolder() {
        pollCount += 1
        let url = FIFinderSyncController.default().targetedURL()
        let path = url?.path
        if path != lastLoggedPath {
            lastLoggedPath = path
            logger.notice("targetedURL -> \(path ?? "nil", privacy: .public)")
        }
        guard let path, path != lastRecordedPath, path != "/" else { return }
        lastRecordedPath = path
        recordCurrentFolder()
    }

    private func recordCurrentFolder() {
        guard let url = FIFinderSyncController.default().targetedURL() else { return }
        PathHistoryStore.shared.record(path: url.path)
        logger.notice("记录目录 \(url.path, privacy: .public)")
    }

    // MARK: - 右键菜单

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let menu = NSMenu(title: "")
        let recordItem = NSMenuItem(title: "记录到最近文件夹", action: #selector(recordAction(_:)), keyEquivalent: "")
        recordItem.target = self
        menu.addItem(recordItem)

        let pinItem = NSMenuItem(title: "置顶为常用目录", action: #selector(pinAction(_:)), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)
        return menu
    }

    @objc private func recordAction(_ sender: AnyObject?) {
        recordCurrentFolder()
    }

    @objc private func pinAction(_ sender: AnyObject?) {
        guard let url = FIFinderSyncController.default().targetedURL() else { return }
        PathHistoryStore.shared.setPinned(true, path: url.path)
        logger.debug("置顶目录 \(url.path, privacy: .public)")
    }
}
