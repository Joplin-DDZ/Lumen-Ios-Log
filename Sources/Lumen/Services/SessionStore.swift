import Foundation
import CSQLite

/// SQLite 只在此 actor 内访问；分页、筛选和写盘均不占用界面线程。
actor SessionStore {
    let root: URL
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        guard sqlite3_open_v2(root.appendingPathComponent("sessions.sqlite").path, &database,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw NSError(domain: "Lumen", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法打开本地日志数据库"])
        }
        sqlite3_busy_timeout(database, 3000)
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, metadata BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS pending_session_deletions(id TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS records(
            session TEXT NOT NULL, id INTEGER NOT NULL, timestamp REAL NOT NULL,
            clock TEXT NOT NULL, level TEXT NOT NULL, process TEXT NOT NULL,
            category TEXT NOT NULL, message TEXT NOT NULL, raw TEXT NOT NULL,
            source TEXT NOT NULL, truncated INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(session,id));
        CREATE INDEX IF NOT EXISTS records_level ON records(session,level,id);
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "Lumen", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法初始化日志数据库"])
        }
        // 正则在 SQLite 后台查询内执行；每条候选记录有截止时间，避免复杂表达式拖住读取器。
        sqlite3_create_function_v2(database, "regexp", 2, SQLITE_UTF8, nil, { context, _, values in
            guard let context, let values,
                  let patternBytes = sqlite3_value_text(values[0]), let textBytes = sqlite3_value_text(values[1]) else {
                sqlite3_result_int(context, 0); return
            }
            let text = String(cString: textBytes)
            let regex: NSRegularExpression
            if let cached = sqlite3_get_auxdata(context, 0) {
                regex = Unmanaged<NSRegularExpression>.fromOpaque(cached).takeUnretainedValue()
            } else {
                guard let compiled = try? NSRegularExpression(pattern: String(cString: patternBytes), options: .caseInsensitive) else { sqlite3_result_int(context, 0); return }
                regex = compiled
                sqlite3_set_auxdata(context, 0, Unmanaged.passRetained(compiled).toOpaque()) { pointer in
                    if let pointer { Unmanaged<NSRegularExpression>.fromOpaque(pointer).release() }
                }
            }
            let deadline = Date().addingTimeInterval(0.03)
            var matched = false
            regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) { match, _, stop in
                if match != nil { matched = true; stop.pointee = true }
                else if Date() > deadline { stop.pointee = true }
            }
            sqlite3_result_int(context, matched ? 1 : 0)
        }, nil, nil, nil)
    }

    deinit { sqlite3_close(database) }

    func saveSession(_ session: LogSession) throws {
        let statement = try prepare("INSERT OR REPLACE INTO sessions(id,metadata) VALUES(?,?)")
        defer { sqlite3_finalize(statement) }
        bind(session.id, at: 1, to: statement)
        let data = try JSONEncoder().encode(session)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }
        try step(statement)
    }

    func sessions() throws -> [LogSession] {
        let statement = try prepare("SELECT metadata,(SELECT COUNT(*) FROM records WHERE session=sessions.id) FROM sessions")
        defer { sqlite3_finalize(statement) }
        var result: [LogSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
            if var session = try? JSONDecoder().decode(LogSession.self, from: data) {
                session.count = Int(sqlite3_column_int64(statement, 1)); result.append(session)
            }
        }
        return result.sorted { $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt }
    }

    /// 元数据与正文在同一事务删除，文件清理意图同时落盘，异常退出后可以重试。
    func deleteSession(_ id: String, protecting protectedIDs: Set<String> = []) throws {
        guard !protectedIDs.contains(id) else {
            throw NSError(domain: "Lumen.Storage", code: 3, userInfo: [NSLocalizedDescriptionKey: "正在采集或导入的会话不能删除。"])
        }
        _ = try deletionFolder(for: id)
        try execute("BEGIN IMMEDIATE")
        do {
            for sql in ["INSERT OR IGNORE INTO pending_session_deletions(id) VALUES(?)", "DELETE FROM records WHERE session=?", "DELETE FROM sessions WHERE id=?"] {
                let statement = try prepare(sql)
                defer { sqlite3_finalize(statement) }
                bind(id, at: 1, to: statement); try step(statement)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        try finishDeletion(id)
        NSLog("[Lumen] 日志会话与原始文件已删除：%@", id)
    }

    /// 跨数据库与文件系统无法原子提交；先持久化待清理项，确保故障不遗留无主文件。
    func retryPendingDeletions() throws {
        let statement = try prepare("SELECT id FROM pending_session_deletions")
        var ids: [String] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { sqlite3_finalize(statement); throw failure() }
            if let value = sqlite3_column_text(statement, 0) { ids.append(String(cString: value)) }
        }
        sqlite3_finalize(statement)
        var firstError: Error?
        for id in ids {
            do { try finishDeletion(id) }
            catch { if firstError == nil { firstError = error }; NSLog("[Lumen] 会话文件待重试清理：%@", id) }
        }
        if let firstError { throw firstError }
    }

    /// 所有类型的会话共同占用保留名额，受保护的活动会话优先保留。
    func pruneSessions(keeping limit: Int = 100, protecting protectedIDs: Set<String> = []) throws {
        precondition(limit > 0)
        let all = try sessions()
        let protected = protectedIDs.union(all.filter { $0.status == "采集中" }.map(\.id))
        let protectedCount = all.filter { protected.contains($0.id) }.count
        let removable = all.filter { !protected.contains($0.id) }.dropFirst(max(0, limit - protectedCount))
        var firstError: Error?
        for session in removable {
            do { try deleteSession(session.id, protecting: protected) }
            catch { if firstError == nil { firstError = error }; NSLog("[Lumen] 旧会话清理失败：%@", session.id) }
        }
        if !removable.isEmpty { NSLog("[Lumen] 超额会话清理完成：候选数=%d 保留上限=%d", removable.count, limit) }
        if let firstError { throw firstError }
    }

    private func finishDeletion(_ id: String) throws {
        let folder = try deletionFolder(for: id)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        let statement = try prepare("DELETE FROM pending_session_deletions WHERE id=?")
        defer { sqlite3_finalize(statement) }
        bind(id, at: 1, to: statement); try step(statement)
    }

    /// ID 只允许单个目录名，且 Sessions 父目录不得通过符号链接指向库外。
    private func deletionFolder(for id: String) throws -> URL {
        let parent = root.appendingPathComponent("Sessions", isDirectory: true)
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\"), !id.contains("\0"),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: parent.path)) == nil else {
            throw NSError(domain: "Lumen.Storage", code: 4, userInfo: [NSLocalizedDescriptionKey: "会话目录路径无效，未执行删除。"])
        }
        return parent.appendingPathComponent(id, isDirectory: true)
    }

    /// 一个批次在同一事务里 upsert；多行追加也能持久化为同一条记录。
    func write(_ records: [LogRecord], sessionID: String) throws {
        guard !records.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("INSERT OR REPLACE INTO records VALUES(?,?,?,?,?,?,?,?,?,?,?)")
            defer { sqlite3_finalize(statement) }
            for record in records {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                bind(sessionID, at: 1, to: statement)
                sqlite3_bind_int64(statement, 2, record.id)
                sqlite3_bind_double(statement, 3, record.timestamp.timeIntervalSince1970)
                for (index, value) in [record.clock, record.level.rawValue, record.process, record.category,
                                       record.message, record.raw, record.source.rawValue].enumerated() {
                    bind(value, at: Int32(index + 4), to: statement)
                }
                sqlite3_bind_int(statement, 11, record.isTruncated ? 1 : 0)
                try step(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK"); throw error
        }
    }

    func count(sessionID: String, filter: LogFilter, before: Int64? = nil) throws -> Int {
        var (whereSQL, parameters) = predicate(sessionID, filter)
        if let before { whereSQL += " AND id < ?"; parameters.append(String(before)) }
        let statement = try prepare("SELECT COUNT(*) FROM records WHERE \(whereSQL)")
        defer { sqlite3_finalize(statement) }; bind(parameters, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func records(sessionID: String, filter: LogFilter, offset: Int, limit: Int) throws -> [LogRecord] {
        let (whereSQL, parameters) = predicate(sessionID, filter)
        let statement = try prepare("SELECT id,timestamp,clock,level,process,category,message,raw,source,truncated FROM records WHERE \(whereSQL) ORDER BY id LIMIT ? OFFSET ?")
        defer { sqlite3_finalize(statement) }; bind(parameters, to: statement)
        sqlite3_bind_int64(statement, Int32(parameters.count + 1), Int64(limit))
        sqlite3_bind_int64(statement, Int32(parameters.count + 2), Int64(offset))
        var result: [LogRecord] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            result.append(readRecord(statement))
        }
        return result
    }

    /// 搜索只保留记录 ID；跳转时加载对应分页，不把整段历史日志读入内存。
    func search(sessionID: String, filter: LogFilter, query: String) throws -> [Int64] {
        guard !query.isEmpty else { return [] }
        var (whereSQL, parameters) = predicate(sessionID, filter)
        whereSQL += " AND (raw LIKE ? ESCAPE '\\' OR category LIKE ? ESCAPE '\\')"
        parameters += [like(query), like(query)]
        let statement = try prepare("SELECT id FROM records WHERE \(whereSQL) ORDER BY id LIMIT 100000")
        defer { sqlite3_finalize(statement) }; bind(parameters, to: statement)
        var result: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(sqlite3_column_int64(statement, 0)) }
        return result
    }

    func maximumID(sessionID: String) throws -> Int64 {
        let statement = try prepare("SELECT COALESCE(MAX(id),0) FROM records WHERE session=?")
        defer { sqlite3_finalize(statement) }; bind(sessionID, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int64(statement, 0)
    }

    /// 导出固定上界快照，采集可以继续；分页流式写入，避免大日志导出耗尽内存。
    func export(sessionID: String, filter: LogFilter, to destination: URL, json: Bool) throws {
        let lastID = try maximumID(sessionID: sessionID)
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".lumen-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: temp) }
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var pageFilter = filter
        while true {
            let page = try records(sessionID: sessionID, filter: pageFilter, offset: 0, limit: 1000).filter { $0.id <= lastID }
            guard !page.isEmpty else { break }
            for record in page {
                let data = try json ? encoder.encode(record) + Data([10]) : Data((record.raw + "\n").utf8)
                try handle.write(contentsOf: data)
            }
            pageFilter.afterID = page.last!.id
            if pageFilter.afterID >= lastID { break }
        }
        try handle.synchronize()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } else { try FileManager.default.moveItem(at: temp, to: destination) }
        NSLog("[Lumen] 日志导出完成：格式=%@", json ? "JSONL" : "TXT")
    }

    func folder(for sessionID: String) throws -> URL {
        let url = root.appendingPathComponent("Sessions/\(sessionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func predicate(_ session: String, _ filter: LogFilter) -> (String, [String]) {
        var sql = "session=? AND id>?", parameters = [session, String(filter.afterID)]
        if !filter.levels.isEmpty {
            let levels = filter.levels.map(\.rawValue).sorted()
            sql += " AND level IN (\(levels.map { _ in "?" }.joined(separator: ",")))"; parameters += levels
        }
        if !filter.include.isEmpty {
            if filter.regex { sql += " AND regexp(?,raw)"; parameters.append(filter.include) }
            else {
                let terms = LogFilter.terms(filter.include)
                if !terms.isEmpty {
                    sql += " AND (" + terms.map { _ in "(raw LIKE ? ESCAPE '\\' OR category LIKE ? ESCAPE '\\')" }.joined(separator: " OR ") + ")"
                    parameters += terms.flatMap { [like($0), like($0)] }
                }
            }
        }
        for term in LogFilter.terms(filter.exclude) {
            sql += " AND raw NOT LIKE ? ESCAPE '\\'"; parameters.append(like(term))
        }
        return (sql, parameters)
    }

    private func like(_ text: String) -> String {
        "%" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
    }
    private func readRecord(_ statement: OpaquePointer) -> LogRecord {
        LogRecord(id: sqlite3_column_int64(statement, 0), timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                  clock: string(statement, 2), level: LogLevel(rawValue: string(statement, 3)) ?? .info,
                  process: string(statement, 4), category: string(statement, 5), message: string(statement, 6),
                  raw: string(statement, 7), source: LogSource(rawValue: string(statement, 8)) ?? .stdout,
                  isTruncated: sqlite3_column_int(statement, 9) != 0)
    }
    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
    private func bind(_ values: [String], to statement: OpaquePointer) {
        for (index, value) in values.enumerated() { bind(value, at: Int32(index + 1), to: statement) }
    }
    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> NSError {
        let detail = sqlite3_errmsg(database).map { String(cString: $0) } ?? "未知错误"
        NSLog("[Lumen] 本地日志存储异常：%@", detail)
        return NSError(domain: "Lumen.Storage", code: 1, userInfo: [NSLocalizedDescriptionKey: "日志存储失败：\(detail)"])
    }
}
