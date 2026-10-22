import Foundation

/// 每个会话内 ID 稳定，多行续写更新同一记录，保留原始格式供导出。
struct LogRecord: Identifiable, Codable, Equatable, Sendable {
    var id: Int64
    var timestamp: Date
    var clock: String
    var level: LogLevel
    var process: String
    var category: String
    var message: String
    var raw: String
    var source: LogSource
    var isTruncated = false

}
