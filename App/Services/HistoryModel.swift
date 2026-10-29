import Foundation
import SwiftUI

/// 菜单栏面板的数据源：读取共享历史，并在文件变化时自动刷新
@MainActor
final class HistoryModel: ObservableObject {

    @Published private(set) var records: [FolderRecord] = []

    private var refreshTimer: Timer?
    private var lastModified: Date?

    init() {
        reload()
        startWatching()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    func reload() {
        lastModified = modificationDate()
        records = PathHistoryStore.shared.all()
    }

    /// 最近目录（面板上方列表）
    var recentRecords: [FolderRecord] {
        Array(records.filter { !$0.isPinned }.prefix(6))
    }

    var pinnedRecords: [FolderRecord] {
        records.filter(\.isPinned)
    }

    func togglePin(_ record: FolderRecord) {
        PathHistoryStore.shared.setPinned(!record.isPinned, path: record.path)
        reload()
    }

    func remove(_ record: FolderRecord) {
        PathHistoryStore.shared.remove(path: record.path)
        reload()
    }

    func reveal(_ record: FolderRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.url])
    }

    func copyPath(_ record: FolderRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.path, forType: .string)
    }

    // MARK: - 私有实现

    private func startWatching() {
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadIfChanged() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func reloadIfChanged() {
        if modificationDate() != lastModified {
            reload()
        }
    }

    private func modificationDate() -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: SharedPaths.historyFileURL.path)
        return attrs?[.modificationDate] as? Date
    }
}
