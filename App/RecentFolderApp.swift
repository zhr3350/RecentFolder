import SwiftUI
import AppKit
import os

@main
struct RecentFolderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            HistoryPanelView(model: appDelegate.historyModel, permissions: appDelegate.permissions)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let historyModel = HistoryModel()
    let permissions = PermissionCenter.shared
    private let savePanelWatcher = SavePanelWatcher()
    private let finderPathTracker = FinderPathTracker()
    private let logger = Logger(subsystem: SharedPaths.logSubsystem, category: "status")

    func applicationDidFinishLaunching(_ notification: Notification) {
        permissions.startPolling()
        // 未授权时主动弹一次系统引导，否则自动跳转链路完全静默失效
        if !permissions.accessibilityGranted {
            permissions.requestAccessibility()
        }
        finderPathTracker.start()
        savePanelWatcher.start()
        logger.notice("启动完成")
    }
}
