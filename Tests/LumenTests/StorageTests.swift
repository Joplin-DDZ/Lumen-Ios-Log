import XCTest
@testable import Lumen

final class StorageTests: XCTestCase {
    private func fixture() throws -> (SessionStore, URL, LogSession) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LumenTests-\(UUID().uuidString)")
        let store = try SessionStore(root: folder)
        let session = LogSession(id: "test", title: "测试", deviceName: "离线设备", process: "App", mode: .device, createdAt: Date(), count: 0, status: "已保存")
        return (store, folder, session)
    }
    private func record(_ id: Int64, _ message: String, level: LogLevel = .info) -> LogRecord {
        LogRecord(id: id, timestamp: Date(timeIntervalSince1970: 1792569480), clock: "16:00:00.000", level: level,
                  process: "App", category: "测试", message: message, raw: message, source: .stdout)
    }

    func testMultiLineUpsertPersistsAcrossReopening() async throws {
        let (store, folder, session) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        try await store.saveSession(session)
        try await store.write([record(1, "首行")], sessionID: session.id)
        try await store.write([record(1, "首行\n续行"), record(2, "下一条")], sessionID: session.id)
        let reopened = try SessionStore(root: folder)
        let count = try await reopened.count(sessionID: session.id, filter: LogFilter())
        let records = try await reopened.records(sessionID: session.id, filter: LogFilter(), offset: 0, limit: 10)
        XCTAssertEqual(count, 2); XCTAssertEqual(records.first?.raw, "首行\n续行")
        let saved = try await reopened.sessions(); XCTAssertEqual(saved.first?.count, 2)
    }

    func testCombinedFilteringLiteralEscapesAndRegex() async throws {
        let (store, folder, session) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        try await store.saveSession(session)
        try await store.write([record(1, "蓝牙 error 100%", level: .error), record(2, "LLM heartbeat", level: .debug),
                               record(3, "LLM response", level: .info), record(4, "1000 regular")], sessionID: session.id)
        let filter = LogFilter(include: "蓝牙,LLM", exclude: "heartbeat", levels: [.error, .info])
        let combined = try await store.records(sessionID: session.id, filter: filter, offset: 0, limit: 10)
        XCTAssertEqual(combined.map(\.id), [1, 3])
        let literal = try await store.count(sessionID: session.id, filter: LogFilter(include: "100%"))
        XCTAssertEqual(literal, 1)
        let regex = try await store.records(sessionID: session.id, filter: LogFilter(include: "LLM\\s+response", regex: true), offset: 0, limit: 10)
        XCTAssertEqual(regex.map(\.id), [3])
    }

    /// 验证真实 SQL 对三种分隔符的 OR 语义，以及排除优先和空项处理。
    func testIncludeAndExcludeAcceptCommaChineseCommaAndPipe() async throws {
        let (store, folder, session) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        try await store.saveSession(session)
        try await store.write([record(1, "蓝牙正常"), record(2, "网络正常"), record(3, "蓝牙心跳"), record(4, "网络重试"), record(5, "其他")], sessionID: session.id)
        for separator in [",", "，", "|"] {
            let filter = LogFilter(include: " 蓝牙\(separator) 网络\(separator) ", exclude: " 心跳\(separator) 重试\(separator) ")
            let rows = try await store.records(sessionID: session.id, filter: filter, offset: 0, limit: 10)
            XCTAssertEqual(rows.map(\.id), [1, 2], "分隔符：\(separator)")
            let excluded = try await store.records(sessionID: session.id, filter: LogFilter(exclude: "心跳\(separator)重试"), offset: 0, limit: 10)
            XCTAssertEqual(excluded.map(\.id), [1, 2, 5])
        }
        XCTAssertEqual(LogFilter.terms(" 蓝牙，网络|心跳,, | "), ["蓝牙", "网络", "心跳"])
    }

    func testSearchCoversUnloadedPagesAndClearViewPreservesHistory() async throws {
        let (store, folder, session) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        try await store.saveSession(session)
        let records = (1...5005).map { record(Int64($0), $0 == 5001 ? "中文目标" : "其他日志 \($0)") }
        try await store.write(records, sessionID: session.id)
        let matches = try await store.search(sessionID: session.id, filter: LogFilter(), query: "目标")
        XCTAssertEqual(matches, [5001])
        let before = try await store.count(sessionID: session.id, filter: LogFilter(), before: 5001)
        let page = try await store.records(sessionID: session.id, filter: LogFilter(), offset: (before / 2000) * 2000, limit: 2000)
        XCTAssertTrue(page.contains(where: { $0.id == 5001 }))
        let cleared = try await store.count(sessionID: session.id, filter: LogFilter(afterID: 5005))
        let original = try await store.count(sessionID: session.id, filter: LogFilter())
        XCTAssertEqual(cleared, 0); XCTAssertEqual(original, 5005)
    }

    func testExportAndJSONLImportRoundTrip() async throws {
        let (store, folder, session) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        try await store.saveSession(session)
        let records = [record(1, "中文\n{\"ok\":true}", level: .error), record(2, "普通输出")]
        try await store.write(records, sessionID: session.id)
        let export = folder.appendingPathComponent("logs.jsonl")
        try await store.export(sessionID: session.id, filter: LogFilter(), to: export, json: true)
        let imported = try await LogImporter.read(export)
        XCTAssertEqual(imported, records)
        let textExport = folder.appendingPathComponent("filtered.txt")
        try await store.export(sessionID: session.id, filter: LogFilter(levels: [.error]), to: textExport, json: false)
        XCTAssertEqual(try String(contentsOf: textExport), records[0].raw + "\n")
    }
}
