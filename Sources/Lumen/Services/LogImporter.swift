import Foundation

/// 离线导入限制文件大小，JSONL 保留结构，普通文本复用实时解析器。
enum LogImporter {
    static func read(_ url: URL) async throws -> [LogRecord] {
        try await Task.detached(priority: .userInitiated) {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 32 * 1024 * 1024 else {
                throw NSError(domain: "Lumen.Import", code: 1, userInfo: [NSLocalizedDescriptionKey: "单次导入支持 32 MB 以内的日志文件。更大日志请分段导入。"])
            }
            let data = try Data(contentsOf: url)
            if url.pathExtension.lowercased() == "jsonl" {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                var records: [LogRecord] = []
                for line in data.split(separator: 10) where !line.isEmpty {
                    var record = try decoder.decode(LogRecord.self, from: Data(line))
                    record.id = Int64(records.count + 1); records.append(record)
                }
                return records
            }
            var sequence: Int64 = 0
            let parser = LogParser(source: .stdout, process: url.deletingPathExtension().lastPathComponent,
                                   nextID: { sequence += 1; return sequence })
            var lines = UTF8LineDecoder()
            for line in lines.feed(data, final: true) { parser.consume(line) }
            return parser.drain()
        }.value
    }
}
