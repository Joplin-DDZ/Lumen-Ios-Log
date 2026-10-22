import Foundation

/// 采集来源与日志级别独立；stderr 不自动等同业务错误。
enum LogSource: String, Codable, Sendable {
    case device, stdout, stderr, system
}
