import Foundation

/// 收藏规则只保存筛选条件，绝不保存或上传日志正文。
struct SavedFilter: Identifiable, Codable, Sendable {
    var id = UUID().uuidString
    var name: String
    var include: String
    var exclude: String
    var regex: Bool
    var levels: [LogLevel]
}
