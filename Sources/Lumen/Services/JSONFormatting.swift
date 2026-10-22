import Foundation

/// 从完整日志中提取对象或数组；格式错误时保留原始文本，不做猜测性修复。
enum JSONFormatting {
    static func pretty(_ text: String) -> String? {
        let candidates: [(Character, Character)] = [("{", "}"), ("[", "]")]
        for (start, end) in candidates {
            guard let first = text.firstIndex(of: start), let last = text.lastIndex(of: end), first <= last,
                  let data = String(text[first...last]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data), JSONSerialization.isValidJSONObject(object),
                  let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { continue }
            return String(data: formatted, encoding: .utf8)
        }
        return nil
    }
}
