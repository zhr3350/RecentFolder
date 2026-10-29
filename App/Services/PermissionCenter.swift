import AppKit
import ApplicationServices
import Combine

/// 集中管理「辅助功能」与「自动化」两类授权状态。
final class PermissionCenter: ObservableObject {

    static let shared = PermissionCenter()

    @Published private(set) var accessibilityGranted: Bool = false

    private var pollTimer: Timer?

    private init() {
        refresh()
    }

    /// 用户可能刚在系统设置里勾选完权限，需要轮询刷新。
    func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func refresh() {
        let granted = AXIsProcessTrusted()
        if granted != accessibilityGranted {
            accessibilityGranted = granted
        }
    }

    /// 弹出系统授权引导。
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
