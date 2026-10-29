import AppKit
import ApplicationServices
import os

/// 监听前台应用弹出保存对话框，在面板旁浮出候选小条，由用户点击决定要不要跳。
///
/// 说明：NSSavePanel 是别的进程的窗口，无法直接设置 directoryURL，
/// 只能通过辅助功能（AX）观察窗口 / 面板创建，再用键盘事件走「前往文件夹」。
final class SavePanelWatcher {

    private let logger = Logger(subsystem: SharedPaths.logSubsystem, category: "save-panel")

    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var settleTimer: Timer?
    private var handledPanels: Set<Int> = []
    private var lastActionAt = Date.distantPast

    /// 是否在保存面板旁浮出候选小条（可在菜单栏面板里关掉）
    static var promptEnabled: Bool {
        UserDefaults.standard.object(forKey: "savePromptEnabled") as? Bool ?? true
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        if let app = NSWorkspace.shared.frontmostApplication {
            observe(appPID: app.processIdentifier)
        }
        logger.notice("保存面板监听已启动，候选小条=\(Self.promptEnabled, privacy: .public)，辅助功能=\(AXIsProcessTrusted(), privacy: .public)")
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        detach()
    }

    // MARK: - 跟踪前台应用

    @objc private func activeAppChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        observe(appPID: app.processIdentifier)
    }

    private func observe(appPID pid: pid_t) {
        guard pid != observedPID, pid != ProcessInfo.processInfo.processIdentifier else { return }
        detach()
        observedPID = pid

        var newObserver: AXObserver?
        let createResult = AXObserverCreate(pid, axObserverCallback, &newObserver)
        guard createResult == .success, let newObserver else {
            logger.notice("创建 AXObserver 失败：\(createResult.rawValue)")
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let notifications: [String] = [
            kAXWindowCreatedNotification,
            kAXFocusedWindowChangedNotification,
            "AXSheetCreated",
        ]
        for name in notifications {
            AXObserverAddNotification(newObserver, appElement, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
        observer = newObserver

        // 保存面板常常在 App 激活的同时就弹出来了，等观察者挂上时窗口已存在，
        // 因此这里立即主动扫一遍，并在随后几秒内继续轻量轮询：
        // 实测 AX 的窗口创建通知会晚到好几秒，只靠通知会明显滞后。
        handleNotification(pid: pid)
        startSettleScan(pid: pid)
    }

    /// 激活后的短时间内反复扫描一次，直到找到保存面板或超时
    private func startSettleScan(pid: pid_t) {
        settleTimer?.invalidate()
        var remaining = 15   // 15 × 0.3s ≈ 4.5s
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            remaining -= 1
            guard remaining > 0, self.observedPID == pid else {
                timer.invalidate()
                self.settleTimer = nil
                return
            }
            self.scan(pid: pid, writeDumpOnMiss: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        settleTimer?.invalidate()
        settleTimer = nil
        handledPanels.removeAll()
    }

    // MARK: - 面板识别

    fileprivate func handleNotification(pid: pid_t) {
        scan(pid: pid, writeDumpOnMiss: true)
    }

    private func scan(pid: pid_t, writeDumpOnMiss: Bool) {
        guard Self.promptEnabled else { return }
        guard Date().timeIntervalSince(lastActionAt) > 1.0 else { return }

        let appElement = AXUIElementCreateApplication(pid)
        guard let panel = findSavePanel(in: appElement) else {
            if writeDumpOnMiss { logger.debug("窗口事件来自没有保存面板的 App（pid \(pid)）") }
            return
        }

        let token = Int(CFHash(panel))
        guard !handledPanels.contains(token) else { return }
        handledPanels.insert(token)

        let candidates = PathHistoryStore.shared.recent(limit: 3)
        guard !candidates.isEmpty else {
            logger.notice("检测到保存面板，但还没有历史目录")
            return
        }

        guard AXIsProcessTrusted() else {
            logger.error("未获得辅助功能授权，无法在小条里点击跳转")
            return
        }

        lastActionAt = Date()
        logger.notice("检测到保存面板，浮出 \(candidates.count) 个候选")
        // 面板的位置和尺寸要等它布局完成才稳定，稍等再贴上去
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            SavePromptPanel.shared.present(
                near: panel,
                ownerPID: pid,
                folders: candidates,
                isAlive: { [weak self] in self?.isPanelAlive(pid: pid) ?? false }
            ) { path in
                self.jump(pid: pid, to: path)
            }
        }
    }

    /// 复用与检测完全相同的识别逻辑，避免小条刚出现就被误判成「面板已消失」
    func isPanelAlive(pid: pid_t) -> Bool {
        findSavePanel(in: AXUIElementCreateApplication(pid)) != nil
    }

    /// 保存面板可能是独立窗口，也可能是挂在文档窗口里的 sheet。
    /// 注意 sheet 不一定出现在 AXSheets 里：TextEdit 的保存框就是
    /// window/AXChildren 下的 `AXSheet id=save-panel`，外层窗口的 subrole
    /// 同时会变成 AXDialog、尺寸仍是整个文档窗口。所以必须先找
    /// `save-panel` 本体，找不到才退回「窗口里有文件名输入框」的判断。
    private func findSavePanel(in appElement: AXUIElement) -> AXUIElement? {
        for window in elements(appElement, kAXWindowsAttribute) {
            if string(window, kAXIdentifierAttribute) == "save-panel" { return window }
            if let sheet = savePanelDescendant(of: window, depth: 0) { return sheet }
        }
        for window in elements(appElement, kAXWindowsAttribute) where hasNameField(in: window, depth: 0) {
            return window
        }
        return nil
    }

    private func savePanelDescendant(of element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 5 else { return nil }
        for child in elements(element, kAXChildrenAttribute) {
            if string(child, kAXIdentifierAttribute) == "save-panel" { return child }
            if let found = savePanelDescendant(of: child, depth: depth + 1) { return found }
        }
        for sheet in elements(element, "AXSheets") {
            if string(sheet, kAXIdentifierAttribute) == "save-panel" { return sheet }
        }
        return nil
    }

    private func hasNameField(in element: AXUIElement, depth: Int) -> Bool {
        guard depth < 6 else { return false }
        if let identifier = string(element, kAXIdentifierAttribute), identifier == "saveAsNameTextField" {
            return true
        }
        for child in elements(element, kAXChildrenAttribute) {
            if hasNameField(in: child, depth: depth + 1) { return true }
        }
        return false
    }

    // MARK: - 键盘注入

    private func jump(pid: pid_t, to path: String) {
        guard AXIsProcessTrusted() else {
            logger.error("未获得辅助功能授权，无法自动跳转")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        logger.notice("注入 ⌘⇧G 跳转到 \(path, privacy: .public)（前台=\(front?.localizedName ?? "?", privacy: .public) pid=\(front?.processIdentifier ?? -1)，目标 pid=\(pid)）")

        postKey(keyCode: 5, flags: [.maskCommand, .maskShift])   // ⌘⇧G 打开「前往文件夹」
        pollGoToFolder(pid: pid, path: path, attempt: 0)
    }

    /// 「前往文件夹」sheet 一出现就立刻写路径并回车。
    /// 原先固定等 1 秒再写、再等 0.5 秒回车，加上 sheet 自身的动画约 1.6 秒才有反应；
    /// 改成 40ms 轮询后通常 0.1 秒内就写进去，视觉上近乎点一下就到。
    private func pollGoToFolder(pid: pid_t, path: String, attempt: Int) {
        // 40ms × 50 次 = 2 秒还没出现就放弃
        guard attempt < 50 else {
            let front = NSWorkspace.shared.frontmostApplication
            logger.error("前往文件夹窗口始终没有出现，放弃跳转（前台=\(front?.localizedName ?? "?", privacy: .public) pid=\(front?.processIdentifier ?? -1)，目标 pid=\(pid)）")
            return
        }
        if fillGoToFolder(pid: pid, path: path) {
            // 这个 sheet 没有确认按钮，只能靠 Return 提交。
            // 只用无修饰键的 Return，避免和微信截图（⌘⇧A）之类的全局快捷键打架。
            postKey(keyCode: 36, flags: [])
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.pollGoToFolder(pid: pid, path: path, attempt: attempt + 1)
        }
    }

    /// 通过 AX 直接把路径写进「前往文件夹」的输入框，不再逐字模拟键盘输入：
    /// 逐字注入中文和空格容易丢字，附带修饰键的模拟按键还可能误触其他 App 的全局快捷键。
    private func fillGoToFolder(pid: pid_t, path: String) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        for window in elements(appElement, kAXWindowsAttribute) {
            guard let field = findElement("PathTextField", in: window, depth: 0) else { continue }
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let result = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, path as CFTypeRef)
            let current = string(field, kAXValueAttribute) ?? ""
            logger.notice("写入前往文件夹路径：结果 \(result.rawValue)，回读 \(current, privacy: .public)")
            return result == .success && current == path
        }
        return false
    }

    private func findElement(_ identifier: String, in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 6 else { return nil }
        if string(element, kAXIdentifierAttribute) == identifier { return element }
        for child in elements(element, kAXChildrenAttribute) {
            if let found = findElement(identifier, in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: - AX 辅助

private func axObserverCallback(observer: AXObserver,
                                element: AXUIElement,
                                notification: CFString,
                                refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let watcher = Unmanaged<SavePanelWatcher>.fromOpaque(refcon).takeUnretainedValue()
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    watcher.handleNotification(pid: pid)
}

private func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let array = value as? [AXUIElement] else { return [] }
    return array
}

private func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
}
