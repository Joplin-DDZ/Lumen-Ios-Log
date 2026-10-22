import Foundation

/// 日志级别保留系统语义，普通标准输出默认归为 info。
enum LogLevel: String, Codable, CaseIterable, Sendable {
    case debug, info, notice, warning, error, fault

    var title: String { rawValue.uppercased() }
    static func infer(_ value: String) -> LogLevel {
        switch value.lowercased() {
        case "d", "debug": return .debug
        case "n", "notice", "default": return .notice
        case "w", "warn", "warning": return .warning
        case "e", "error", "err": return .error
        case "f", "fault", "fatal": return .fault
        default: return .info
        }
    }
}
