import SwiftUI
import AppKit

@main
struct RecentFolderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("最近文件夹", systemImage: "folder.badge.gearshape") {
            HistoryPanelView(model: appDelegate.historyModel, permissions: appDelegate.permissions)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        permissions.startPolling()
        // 未授权时主动弹一次系统引导，否则自动跳转链路完全静默失效
        if !permissions.accessibilityGranted {
            permissions.requestAccessibility()
        }
        finderPathTracker.start()
        savePanelWatcher.start()
        NSLog("[RecentFolder] launched, history=\(SharedPaths.historyFileURL.path)")
    }
}
