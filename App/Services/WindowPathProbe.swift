import ApplicationServices
import AppKit

/// 从任意 App 的前台窗口里"猜"出当前文件夹路径。
///
/// 访达不支持 `AXDocument`（实测 -25212 attribute unsupported，标题多数时候只是
/// 文件夹名），所以访达仍然走 AppleScript；三方文件管理器没有统一契约，只能按
/// 下面的顺序探测，命中即止：`AXDocument` → 路径样式的文本框 → 窗口标题。
enum WindowPathProbe {

    static func path(of pid: pid_t) -> String? {
        guard let window = frontWindow(of: pid) else { return nil }
        if let path = documentPath(of: window) { return path }
        if let path = pathField(in: window, depth: 0) { return path }
        return validPath(string(of: window, kAXTitleAttribute))
    }

    /// 窗口标题。访达用它当"目录可能变了"的廉价信号，避免每次都跑 AppleScript。
    static func title(of pid: pid_t) -> String? {
        guard let window = frontWindow(of: pid) else { return nil }
        return string(of: window, kAXTitleAttribute)
    }

    // MARK: - 探测

    private static func frontWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        // 对端卡死时 AX 调用会一直阻塞，必须设超时
        AXUIElementSetMessagingTimeout(app, 0.3)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        return elements(app, kAXWindowsAttribute).first
    }

    private static func documentPath(of element: AXUIElement) -> String? {
        if let value = string(of: element, kAXDocumentAttribute) {
            return validPath(value)
        }
        for child in elements(element, kAXChildrenAttribute) {
            if let value = string(of: child, kAXDocumentAttribute), let path = validPath(value) {
                return path
            }
        }
        return nil
    }

    private static func pathField(in element: AXUIElement, depth: Int) -> String? {
        guard depth < 6 else { return nil }
        let role = string(of: element, kAXRoleAttribute) ?? ""
        if role == (kAXTextFieldRole as String) || role == (kAXStaticTextRole as String) {
            if let path = validPath(string(of: element, kAXValueAttribute)) { return path }
            if let path = validPath(string(of: element, kAXDescriptionAttribute)) { return path }
        }
        for child in elements(element, kAXChildrenAttribute) {
            if let path = pathField(in: child, depth: depth + 1) { return path }
        }
        return nil
    }

    /// 只接受"确实存在的绝对路径"，否则窗口里随便一段以 / 开头的文字都会被当目录
    private static func validPath(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL else { return nil }
            text = url.path
        }
        if text.hasPrefix("~") {
            text = (text as NSString).expandingTildeInPath
        }
        guard text.hasPrefix("/") else { return nil }
        let path = (text as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return path
    }

    // MARK: - AX 辅助

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
