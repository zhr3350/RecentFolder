import AppKit
import ApplicationServices
import SwiftUI
import os

/// 保存面板旁边浮出的小条：列出最近几个文件夹，用户点了才跳转。
///
/// 刻意做的几件事：
/// 1. `nonactivatingPanel` —— 点击不会把我们的 App 激活，目标 App 始终留在前台，
///    后续注入的 ⌘⇧G 才会发给正确的进程。
/// 2. 不替用户做任何决定 —— 不点，保存面板就停在系统原来的位置。
/// 3. 保存面板一消失（保存、取消、Esc）小条立刻收起，不留残影。
/// 4. 面板动、小条跟着动；面板所属 App 不在前台时一块儿藏起来，
///    避免小条单独浮在别的 App 之上。
final class SavePromptPanel {

    static let shared = SavePromptPanel()

    private let logger = Logger(subsystem: SharedPaths.logSubsystem, category: "save-prompt")

    private var strip: StripPanel?
    private var watchdog: Timer?
    private var pickHandler: ((String) -> Void)?
    /// 复用 SavePanelWatcher 的识别逻辑判断面板是否还在，
    /// 避免两处判定标准不一致导致小条刚出现就被收走
    private var isAlive: (() -> Bool)?
    /// 面板本体和它所属的进程，用于跟随移动与跟随前后台
    private var panelRef: AXUIElement?
    private var panelPID: pid_t = 0

    private init() {}

    // MARK: - 展示 / 收起

    func present(near axPanel: AXUIElement,
                 ownerPID: pid_t,
                 folders: [FolderRecord],
                 isAlive: @escaping () -> Bool,
                 onPick: @escaping (String) -> Void) {
        guard !folders.isEmpty else { return }
        dismiss()
        pickHandler = onPick
        self.isAlive = isAlive
        panelRef = axPanel
        panelPID = ownerPID

        // 宽度对齐保存面板，但给上限：某些 App 的「面板」其实是挂在文档窗口里的
        // sheet，AX 上报的是整个窗口的尺寸，直接跟随会横跨半个屏幕。
        let panelFrame = axFrame(of: axPanel)
        let width = min(max(panelFrame?.width ?? 380, 320), 460)
        logger.notice("保存面板 frame=\(String(describing: panelFrame), privacy: .public)，小条宽度=\(width)")

        let view = SavePromptView(folders: folders, width: width) { [weak self] path in
            guard let self, let handler = self.pickHandler else { return }
            logger.notice("用户选择 \(path, privacy: .public)，已复制路径，小条保持显示")
            // 只留最小的间隔，让这次点击先结束，别和注入的按键抢时序
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { handler(path) }
        }

        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize

        let window = StripPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // 保存面板的 sheet 位于 .modalPanel 这一层，它自己的投影会落在紧贴下方的
        // 小条上，看起来就像中间夹了一条灰缝。把小条抬到它上面，白色底就把阴影
        // 盖住了，交界处是一条干净的硬边。
        window.level = NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        // 小条自己不加阴影，否则会在面板交界处再压出一条灰带
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.contentView = hosting
        window.setFrameOrigin(origin(for: size, panelFrame: panelFrame))
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
        panelRef = nil
        panelPID = 0
        strip?.orderOut(nil)
        strip?.contentView = nil
        strip = nil
    }

    // MARK: - 跟随保存面板

    /// 0.25 秒一拍，做三件事：
    /// - 跟随面板位置：面板移动（含刚弹出时的动画）时小条贴回去
    /// - 跟随前后台：面板所属 App 不在前台时把小条藏起来，切回来再露出
    /// - 面板是否还在：直接复用 SavePanelWatcher 的识别逻辑，保证两侧标准一致。
    ///   AX 偶发查不到不算消失，连续三次（约 1.5 秒）才收；上限 2 分钟。
    private func startWatchdog() {
        let startedAt = Date()
        var tick = 0
        var missCount = 0
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            tick += 1
            if Date().timeIntervalSince(startedAt) > 120 {
                self.logger.notice("小条超时收起")
                self.dismiss()
                return
            }

            if let panel = self.panelRef, let window = self.strip {
                let point = self.origin(for: window.frame.size, panelFrame: self.axFrame(of: panel))
                if window.frame.origin != point {
                    window.setFrameOrigin(point)
                }
            }

            // 前后台每拍都看，开销只是一次 NSWorkspace 查询。
            // 比对的是面板所属的 App，而不是面板窗口自己的 pid：沙盒 App 的保存
            // 面板由 openAndSavePanelService 代开，那个 pid 永远不是前台。
            if let window = self.strip {
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if front == self.panelPID {
                    window.orderFrontRegardless()
                } else {
                    window.orderOut(nil)
                }
            }

            // 面板是否还在：AX 树遍历略贵，隔一拍查一次
            guard tick % 2 == 0 else { return }
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

    private func origin(for size: NSSize, panelFrame frame: NSRect?) -> NSPoint {
        let primary = NSScreen.screens.first
        let fallbackVisible = NSScreen.main?.visibleFrame ?? primary?.visibleFrame ?? .zero

        guard let frame, let primary else {
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

        // 紧贴面板正下方，不留缝；左边缘对齐
        var point = NSPoint(x: anchor.minX, y: anchor.minY - size.height)
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

    @State private var hoveredPath: String?
    @State private var copiedPath: String?

    /// 底部圆角比系统面板略大一点，方角会让小条显得更宽
    private let cornerRadius: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            ForEach(folders) { folder in
                row(folder)
            }
        }
        .padding(.vertical, 3)
        .frame(width: width)
        // 和保存面板的白色内容区对齐，贴在下面才像同一块面板
        .background(Color(nsColor: .textBackgroundColor))
        // 顶部两角做成直角：小条要零缝隙贴在保存面板下方，
        // 留圆角的话交界处会露出去两个小缺口，看起来像没贴住。
        .clipShape(shape)
        // 只描左、右、下三边。顶边再画一道线，等于在贴合处划出一条「缝」
        .overlay(ThreeSideBorder(cornerRadius: cornerRadius).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: cornerRadius,
            bottomTrailingRadius: cornerRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    private func row(_ folder: FolderRecord) -> some View {
        Button {
            copy(folder.path)
            onPick(folder.path)
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(folder.path)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if copiedPath == folder.path {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
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
        .help("点击跳转到该文件夹，并复制它的路径")
    }

    /// 复制路径，小条不收起：可能只是想拿路径去粘贴，也可能要连着跳几个位置。
    private func copy(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        copiedPath = path
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedPath == path { copiedPath = nil }
        }
    }
}

// MARK: - 形状

/// 左、右、下三边的描边，顶边不画
private struct ThreeSideBorder: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = cornerRadius
        let minX = rect.minX + 0.5
        let maxX = rect.maxX - 0.5
        let minY = rect.minY - 1      // 往上多画一点，顶部切口不会被裁出毛边
        let maxY = rect.maxY - 0.5

        var path = Path()
        path.move(to: CGPoint(x: minX, y: minY))
        path.addLine(to: CGPoint(x: minX, y: maxY - r))
        path.addQuadCurve(to: CGPoint(x: minX + r, y: maxY),
                          control: CGPoint(x: minX, y: maxY))
        path.addLine(to: CGPoint(x: maxX - r, y: maxY))
        path.addQuadCurve(to: CGPoint(x: maxX, y: maxY - r),
                          control: CGPoint(x: maxX, y: maxY))
        path.addLine(to: CGPoint(x: maxX, y: minY))
        return path
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
