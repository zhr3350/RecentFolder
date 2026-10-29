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
    /// 复用 SavePanelWatcher 的识别逻辑判断面板是否还在，
    /// 避免两处判定标准不一致导致小条刚出现就被收走
    private var isAlive: (() -> Bool)?

    private init() {}

    // MARK: - 展示 / 收起

    func present(near axPanel: AXUIElement,
                 folders: [FolderRecord],
                 isAlive: @escaping () -> Bool,
                 onPick: @escaping (String) -> Void) {
        guard !folders.isEmpty else { return }
        dismiss()
        pickHandler = onPick
        self.isAlive = isAlive

        // 宽度对齐保存面板，但给上限：某些 App 的「面板」其实是挂在文档窗口里的
        // sheet，AX 上报的是整个窗口的尺寸，直接跟随会横跨半个屏幕。
        let panelFrame = axFrame(of: axPanel)
        let width = min(max(panelFrame?.width ?? 380, 320), 460)
        logger.notice("保存面板 frame=\(String(describing: panelFrame), privacy: .public)，小条宽度=\(width)")

        let view = SavePromptView(
            folders: folders,
            width: width,
            onPick: { [weak self] path in
                guard let self, let handler = self.pickHandler else { return }
                logger.notice("用户选择跳转到 \(path, privacy: .public)")
                dismiss()
                // 只留最小的间隔，让这次点击先结束，别和注入的按键抢时序
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { handler(path) }
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

        startWatchdog()
        logger.notice("已浮出候选小条，\(folders.count) 个候选，位置 \(NSStringFromRect(window.frame), privacy: .public)")
    }

    func dismiss() {
        watchdog?.invalidate()
        watchdog = nil
        pickHandler = nil
        isAlive = nil
        strip?.orderOut(nil)
        strip?.contentView = nil
        strip = nil
    }

    // MARK: - 跟随保存面板

    /// 保存面板一旦真的消失就收起小条，但判定要宽容：
    /// - 面板是否还在，直接复用 SavePanelWatcher 的识别逻辑，保证两侧标准一致
    /// - AX 查询偶发失败不能算「面板消失」，连续三次查不到才收（约 1.5 秒）
    /// - 不按「前台 App 是否等于面板 pid」判断。沙盒 App 的保存面板由
    ///   com.apple.appkit.xpc.openAndSavePanelService 代开，pid 天生不一致，
    ///   按前台判断会在 1.5 秒内误收小条。
    /// - 上限 2 分钟，用户输文件名时不会被打断。
    private func startWatchdog() {
        let startedAt = Date()
        var missCount = 0
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(startedAt) > 120 {
                self.logger.notice("小条超时收起")
                self.dismiss()
                return
            }
            if self.isAlive?() ?? false {
                missCount = 0
                return
            }
            missCount += 1
            if missCount >= 3 {
                self.logger.notice("保存面板已消失，收起小条")
                self.dismiss()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    // MARK: - 位置

    private func origin(for size: NSSize, near axPanel: AXUIElement) -> NSPoint {
        let primary = NSScreen.screens.first
        let fallbackVisible = NSScreen.main?.visibleFrame ?? primary?.visibleFrame ?? .zero

        guard let frame = axFrame(of: axPanel), let primary else {
            return NSPoint(x: fallbackVisible.midX - size.width / 2,
                           y: fallbackVisible.midY - size.height / 2)
        }

        // AX 用左上原点，Cocoa 用左下原点，以主屏上边缘为基准翻转
        let anchor = NSRect(x: frame.minX,
                            y: primary.frame.maxY - frame.maxY,
                            width: frame.width,
                            height: frame.height)

        // 用面板所在的那块屏幕做边界
        let visible = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY))
        }?.visibleFrame ?? fallbackVisible

        // 贴在面板正下方，左边缘对齐
        var point = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 8)
        if point.y < visible.minY + 8 {
            // 面板贴着屏幕底部时，宁可放在屏幕最下方，也不翻到菜单栏下面——
            // 那样会离面板很远，反而挡住别的窗口标题栏
            point.y = visible.minY + 8
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
    let width: CGFloat
    let onPick: (String) -> Void
    let onCancel: () -> Void

    @State private var hoveredPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(spacing: 1) {
                ForEach(folders) { folder in
                    row(folder)
                }
            }
            .padding(.vertical, 4)
            Divider()
            Text("不点就保持系统原来的位置")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(width: width)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("跳到最近文件夹")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭，保存面板保持原位")
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 8)
    }

    private func row(_ folder: FolderRecord) -> some View {
        Button {
            onPick(folder.path)
        } label: {
            HStack(spacing: 9) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                    .resizable()
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.displayName)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(folder.path)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hoveredPath == folder.path ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredPath = folder.path
            } else if hoveredPath == folder.path {
                hoveredPath = nil
            }
        }
        .padding(.horizontal, 5)
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
