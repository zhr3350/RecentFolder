import AppKit
import ApplicationServices
import SwiftUI
import os

/// 保存面板旁边浮出的小条：列出最近几个文件夹，用户点了才跳转。
///
/// 刻意做的三件事：
/// 1. `nonactivatingPanel` —— 点击不会把我们的 App 激活，目标 App 始终留在前台，
///    后续注入的 ⌘⇧G 才会发给正确的进程。
/// 2. 不替用户做任何决定 —— 不点、点关闭，保存面板就停在系统原来的位置。
/// 3. 保存面板一消失（保存、取消、Esc）小条立刻收起，不留残影。
final class SavePromptPanel {

    static let shared = SavePromptPanel()

    private let logger = Logger(subsystem: SharedPaths.logSubsystem, category: "save-prompt")

    private var strip: StripPanel?
    private var watchdog: Timer?
    private var pickHandler: ((String) -> Void)?

    private init() {}

    // MARK: - 展示 / 收起

    func present(near axPanel: AXUIElement, folders: [FolderRecord], onPick: @escaping (String) -> Void) {
        guard !folders.isEmpty else { return }
        dismiss()
        pickHandler = onPick

        let view = SavePromptView(
            folders: folders,
            onPick: { [weak self] path in
                guard let self, let handler = self.pickHandler else { return }
                logger.notice("用户选择跳转到 \(path, privacy: .public)")
                dismiss()
                // 等这次点击彻底结束再注入按键，避免和鼠标事件抢时序
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { handler(path) }
            },
            onCancel: { [weak self] in
                self?.logger.notice("用户关闭了小条，保存面板保持原位")
                self?.dismiss()
            }
        )

        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize

        let window = StripPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.contentView = hosting
        window.setFrameOrigin(origin(for: size, near: axPanel))
        window.orderFrontRegardless()

        strip = window

        var pid: pid_t = 0
        AXUIElementGetPid(axPanel, &pid)
        startWatchdog(pid: pid)
        logger.notice("已浮出候选小条，\(folders.count) 个候选")
    }

    func dismiss() {
        watchdog?.invalidate()
        watchdog = nil
        pickHandler = nil
        strip?.orderOut(nil)
        strip?.contentView = nil
        strip = nil
    }

    // MARK: - 跟随保存面板

    private func startWatchdog(pid: pid_t) {
        let startedAt = Date()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed > 25 || !self.hasSavePanel(pid: pid) {
                self.dismiss()
                return
            }
            // 用户切到别的 App 就把小条收起来；刚弹出时焦点切换有延迟，留 1.5s 缓冲
            if elapsed > 1.5, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                self.dismiss()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func hasSavePanel(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        for window in elements(app, kAXWindowsAttribute) {
            if identifier(window) == "save-panel" { return true }
            for sheet in elements(window, "AXSheets") where identifier(sheet) == "save-panel" {
                return true
            }
        }
        return false
    }

    // MARK: - 位置

    private func origin(for size: NSSize, near axPanel: AXUIElement) -> NSPoint {
        let primary = NSScreen.screens.first
        let visible = NSScreen.main?.visibleFrame ?? primary?.visibleFrame ?? .zero

        guard let frame = axFrame(of: axPanel), let primary else {
            return NSPoint(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24)
        }

        // AX 用左上原点，Cocoa 用左下原点，以主屏上边缘为基准翻转
        let anchor = NSRect(x: frame.minX,
                            y: primary.frame.maxY - frame.maxY,
                            width: frame.width,
                            height: frame.height)

        var point = NSPoint(x: anchor.maxX + 12, y: anchor.maxY - size.height)
        if point.x + size.width > visible.maxX {
            point.x = anchor.minX - size.width - 12      // 右边放不下就放左边
        }
        if point.x < visible.minX {
            point.x = anchor.midX - size.width / 2        // 左右都放不下就放下面
            point.y = anchor.minY - size.height - 8
        }
        point.x = min(max(point.x, visible.minX + 8), visible.maxX - size.width - 8)
        point.y = min(max(point.y, visible.minY + 8), visible.maxY - size.height - 8)
        return point
    }

    private func axFrame(of element: AXUIElement) -> NSRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef else { return nil }

        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &extent) else { return nil }
        return NSRect(origin: point, size: extent)
    }
}

// MARK: - 窗口

/// 不能成为 key/main：这样点击它不会抢走保存面板的键盘焦点，也不会激活本 App
private final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 视图

private struct SavePromptView: View {

    let folders: [FolderRecord]
    let onPick: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            ForEach(folders) { folder in
                row(folder)
            }
            Divider().opacity(0.5)
            Text("不点就保持系统原来的位置")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .frame(width: 272)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("跳到最近文件夹")
                .font(.system(size: 11, weight: .medium))
            Spacer(minLength: 8)
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func row(_ folder: FolderRecord) -> some View {
        Button {
            onPick(folder.path)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(folder.path)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AX 辅助

private func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let array = value as? [AXUIElement] else { return [] }
    return array
}

private func identifier(_ element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &value) == .success else { return nil }
    return value as? String
}
