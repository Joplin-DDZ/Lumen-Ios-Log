import Foundation

/// 包含条件按 OR 匹配，排除条件按任意命中隐藏，正则模式不拆分表达式。
struct LogFilter: Equatable, Sendable {
    var include = ""
    var exclude = ""
    var regex = false
    var levels: Set<LogLevel> = []
    var afterID: Int64 = 0

    var validationError: String? {
        guard regex, !include.isEmpty else { return nil }
        do { _ = try NSRegularExpression(pattern: include, options: .caseInsensitive); return nil }
        catch { return "正则表达式无效：\(error.localizedDescription)" }
    }
    var hasConditions: Bool { !include.isEmpty || !exclude.isEmpty || !levels.isEmpty }
    /// 包含和排除共用 OR 分词，兼容中英文逗号和竖线，忽略空项与首尾空白。
    static func terms(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: ",，|")).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }
}
