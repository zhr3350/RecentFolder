import Foundation

/// 应用数据目录。原先要与 Finder 扩展共享，故优先用 App Group；
/// 扩展移除后只剩单进程，直接用 Application Support 下的固定目录。
enum SharedPaths {
    static let logSubsystem = "com.haoran.recentfolder"

    /// ~/Library/Application Support/RecentFolder
    static func sharedDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("RecentFolder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var historyFileURL: URL {
        sharedDirectory().appendingPathComponent("history.json", isDirectory: false)
    }
}

/// 最近文件夹历史的读写入口，以 JSON 文件持久化。
final class PathHistoryStore {
    static let shared = PathHistoryStore()

    private let queue = DispatchQueue(label: "com.haoran.recentfolder.history")
    private let limit = 50

    // MARK: - 读取

    /// 置顶优先，其余按最近访问时间倒序
    func all() -> [FolderRecord] {
        queue.sync { sorted(read()) }
    }

    /// 最近使用的若干个目录（跳过置顶项之外的临时路径无需处理，保持简单）
    func recent(limit count: Int) -> [FolderRecord] {
        Array(all().prefix(count))
    }

    // MARK: - 写入

    /// 去掉尾部斜杠（根目录除外），避免同一目录以两种写法重复入库
    static func normalize(_ path: String) -> String {
        guard path.count > 1 else { return path }
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    @discardableResult
    func record(path rawPath: String, at date: Date = Date()) -> [FolderRecord] {
        let path = Self.normalize(rawPath)
        guard !path.isEmpty else { return all() }
        return queue.sync {
            var records = read()
            if let index = records.firstIndex(where: { $0.path == path }) {
                records[index].lastVisit = date
                records[index].visitCount += 1
            } else {
                records.append(FolderRecord(path: path, lastVisit: date, visitCount: 1, isPinned: false))
            }
            // 超出上限时丢弃最久未访问的非置顶记录
            if records.count > limit {
                let sortedOut = sorted(records)
                records = Array(sortedOut.prefix(limit))
            }
            write(records)
            return sorted(records)
        }
    }

    @discardableResult
    func setPinned(_ pinned: Bool, path: String) -> [FolderRecord] {
        queue.sync {
            var records = read()
            if let index = records.firstIndex(where: { $0.path == path }) {
                records[index].isPinned = pinned
                write(records)
            }
            return sorted(records)
        }
    }

    @discardableResult
    func remove(path: String) -> [FolderRecord] {
        queue.sync {
            let records = read().filter { $0.path != path }
            write(records)
            return sorted(records)
        }
    }

    // MARK: - 私有实现

    private func sorted(_ records: [FolderRecord]) -> [FolderRecord] {
        records.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.lastVisit > rhs.lastVisit
        }
    }

    private func read() -> [FolderRecord] {
        guard let data = try? Data(contentsOf: SharedPaths.historyFileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([FolderRecord].self, from: data)) ?? []
    }

    private func write(_ records: [FolderRecord]) {
        let url = SharedPaths.historyFileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            // 先写临时文件再原子替换，避免另一个进程读到半截内容
            let temp = url.deletingLastPathComponent()
                .appendingPathComponent("history-\(UUID().uuidString).tmp")
            try data.write(to: temp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            NSLog("[RecentFolder] 写入历史失败: \(error.localizedDescription)")
        }
    }
}
