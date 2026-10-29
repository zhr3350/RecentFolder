import Foundation

/// 一条最近访问过的文件夹记录
struct FolderRecord: Codable, Hashable, Identifiable {
    var path: String
    var lastVisit: Date
    var visitCount: Int
    var isPinned: Bool

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String { url.lastPathComponent.isEmpty ? path : url.lastPathComponent }
}
