import Foundation

/// 设备日志、KMP 和 LOOI 时间戳各自识别；无法识别时原样降级，不丢弃日志。
final class LogParser {
    private let source: LogSource
    private let process: String
    private let nextID: () -> Int64
    private var current: LogRecord?
    private var grouping = false
    private var dirty: [Int64: LogRecord] = [:]
    private static let deviceHeader = try! NSRegularExpression(pattern: #"^\w{3}\s+\d+\s+(\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+(.+?)(?:\((.*?)\))?\[(\d+)\]\s+<([^>]+)>:\s?(.*)$"#)
    private static let appHeader = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}\s+(\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+\[(?:Main|BG)\]\s+(\w+)\s+.*?\s-\s?(.*)$"#)
    /// NSLog 的时间戳与进程头也构成新消息，防止被并入前一条 KMP 多行正文。
    private static let nsLogHeader = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}\s+(\d{2}:\d{2}:\d{2}(?:\.\d+)?)(?:[+-]\d{4})?\s+(.+?)\[\d+(?::[^\]]+)?\]\s?(.*)$"#)
    private static let kmpHeader = try! NSRegularExpression(pattern: #"^KMP\[([A-Z])\]\[([^\]]+)\]\s?(.*)$"#)
    private let clock: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.SSS"; return formatter
    }()

    init(source: LogSource, process: String, nextID: @escaping () -> Int64) {
        self.source = source; self.process = process; self.nextID = nextID
    }

    func consume(_ line: String) {
        var record = LogRecord(id: 0, timestamp: Date(), clock: clock.string(from: Date()), level: .info,
                               process: process, category: "", message: line, raw: line, source: source)
        var recognized = false
        if let fields = match(Self.deviceHeader, line) {
            record.clock = fields[1]; record.process = fields[2]; record.category = fields[3]
            record.level = .infer(fields[5]); record.message = fields[6]; record.source = .device
            recognized = true
        } else if let fields = match(Self.appHeader, line) {
            record.clock = fields[1]; record.level = .infer(fields[2]); record.message = fields[3]
            recognized = true
        } else if let fields = match(Self.nsLogHeader, line) {
            record.clock = fields[1]; record.process = fields[2]; record.message = fields[3]
            recognized = true
        } else if let fields = match(Self.kmpHeader, line) {
            record.level = .infer(fields[1]); record.category = fields[2]; record.message = fields[3]
            recognized = true
        } else if source == .device && (line.hasPrefix("[connected:") || line.hasPrefix("[disconnected:")) {
            record.source = .system; record.process = "Lumen"; record.category = "采集通道"
            recognized = true
        }
        if !recognized, grouping, var previous = current {
            if previous.raw.utf8.count + line.utf8.count < 512 * 1024 {
                previous.message += "\n" + line; previous.raw += "\n" + line
            } else if !previous.isTruncated {
                previous.message += "\n[消息过长，完整内容保留在会话原始文件中]"; previous.isTruncated = true
            }
            current = previous; dirty[previous.id] = previous
            return
        }
        guard !line.isEmpty else { return }
        record.id = nextID()
        current = record; dirty[record.id] = record
        grouping = recognized && record.source != .system
    }

    /// 批量交付有变化的快照，同一条多行日志不会在 UI 重复插入。
    func drain() -> [LogRecord] {
        let records = dirty.values.sorted { $0.id < $1.id }; dirty.removeAll(keepingCapacity: true); return records
    }

    private func match(_ regex: NSRegularExpression, _ text: String) -> [String]? {
        guard let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<found.numberOfRanges).map { index in
            Range(found.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

}
