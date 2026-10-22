import XCTest
import CSQLite
@testable import Lumen

final class SessionRetentionTests: XCTestCase {
    private func session(_ id: String, time: TimeInterval = 0) -> LogSession {
        LogSession(id: id, title: "测试会话", deviceName: "测试设备", process: "App", mode: .console, createdAt: Date(timeIntervalSince1970: time), count: 0, status: "已保存")
    }
    private func record() -> LogRecord {
        LogRecord(id: 1, timestamp: Date(), clock: "", level: .info, process: "App", category: "", message: "测试正文", raw: "测试正文", source: .stdout)
    }

    /// 删除必须同时处理索引、全文搜索与原始文件，其他会话不受影响。
    func testDeleteRemovesDatabaseAndFilesAndIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        for id in ["remove", "keep"] {
            try await store.saveSession(session(id))
            try await store.write([record()], sessionID: id)
            let folder = try await store.folder(for: id)
            try Data("原文".utf8).write(to: folder.appendingPathComponent("stdout.log"))
        }
        try await store.deleteSession("remove")
        try await store.deleteSession("remove")
        let sessions = try await store.sessions()
        let count = try await store.count(sessionID: "remove", filter: LogFilter())
        let matches = try await store.search(sessionID: "remove", filter: LogFilter(), query: "测试")
        let kept = try await store.count(sessionID: "keep", filter: LogFilter())
        XCTAssertEqual(sessions.map(\.id), ["keep"])
        XCTAssertEqual(count, 0); XCTAssertTrue(matches.isEmpty); XCTAssertEqual(kept, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sessions/remove").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sessions/keep/stdout.log").path))
    }

    /// 活动会话即使最旧也不能被清理，其余名额保留最新的历史。
    func testRetentionKeeps100IncludingProtectedOldSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        for index in 0..<103 {
            let id = "session-\(index)"
            try await store.saveSession(session(id, time: Double(index)))
            try await store.write([record()], sessionID: id)
            let folder = try await store.folder(for: id)
            try Data("原文".utf8).write(to: folder.appendingPathComponent("stdout.log"))
        }
        try await store.pruneSessions(protecting: ["session-0"])
        let retained = try await store.sessions()
        XCTAssertEqual(retained.count, 100)
        XCTAssertEqual(Set(retained.map(\.id)), Set(["session-0"] + (4..<103).map { "session-\($0)" }))
        for index in 1...3 {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sessions/session-\(index)").path))
            let count = try await store.count(sessionID: "session-\(index)", filter: LogFilter())
            XCTAssertEqual(count, 0)
        }
        try await store.pruneSessions(protecting: ["session-0"])
        let unchanged = try await store.sessions()
        XCTAssertEqual(unchanged.count, 100)
        do { try await store.deleteSession("session-0", protecting: ["session-0"]); XCTFail("活动会话被删除") }
        catch { }
        let protected = try await store.count(sessionID: "session-0", filter: LogFilter())
        XCTAssertEqual(protected, 1)
    }

    /// 数据库已经提交、文件尚未处理时退出，重开后必须补齐清理且不触及其他路径。
    func testPendingDeletionRecoversAcrossReopeningAndRejectsEscapingPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        let folder = try await store.folder(for: "pending")
        try Data("未清理原文".utf8).write(to: folder.appendingPathComponent("stderr.log"))
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("sessions.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "INSERT INTO pending_session_deletions VALUES('pending')", nil, nil, nil), SQLITE_OK)
        let reopened = try SessionStore(root: root)
        try await reopened.retryPendingDeletions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        try await reopened.retryPendingDeletions()
        for id in ["../outside", ".", "..", "", "nested/path"] {
            do { try await reopened.deleteSession(id); XCTFail("无效路径被接受") }
            catch { }
        }
    }

    /// 自动清理统一计算导入与旧类型会话，采集中状态也受到存储层保护。
    func testRetentionCountsAllTypesAndProtectsRecordingStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var active = session("active", time: 0); active.status = "采集中"
        var legacy = session("legacy", time: 1); legacy.mode = .device
        var imported = session("imported", time: 2); imported.status = "已导入"
        for item in [active, legacy, imported, session("newest", time: 3)] { try await store.saveSession(item) }
        try await store.pruneSessions()
        let initial = try await store.sessions()
        XCTAssertEqual(initial.count, 4)
        try await store.pruneSessions(keeping: 2)
        let retained = try await store.sessions()
        XCTAssertEqual(Set(retained.map(\.id)), ["active", "newest"])
    }

    /// 数据库删除失败时正文、元数据和待清理项一起回滚，不能留下半删除状态。
    func testDatabaseFailureRollsBackBeforeRemovingRawFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        try await store.saveSession(session("keep"))
        try await store.write([record()], sessionID: "keep")
        let folder = try await store.folder(for: "keep")
        try Data("原文".utf8).write(to: folder.appendingPathComponent("stdout.log"))
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("sessions.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER reject_delete BEFORE DELETE ON sessions BEGIN SELECT RAISE(ABORT, 'test failure'); END", nil, nil, nil), SQLITE_OK)
        do { try await store.deleteSession("keep"); XCTFail("故障未生效") }
        catch { }
        try await store.retryPendingDeletions()
        let count = try await store.count(sessionID: "keep", filter: LogFilter())
        let retained = try await store.sessions()
        XCTAssertEqual(count, 1); XCTAssertEqual(retained.map(\.id), ["keep"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("stdout.log").path))
    }

    /// 文件清理路径校验失败时，事务之前终止，数据库和外部数据仍保留。
    func testSymlinkParentCannotDeleteOutsideLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let store = try SessionStore(root: root)
        try await store.saveSession(session("keep"))
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("keep"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Sessions"), withDestinationURL: outside)
        do { try await store.deleteSession("keep"); XCTFail("符号链接逃逸被接受") }
        catch { }
        let retained = try await store.sessions()
        XCTAssertEqual(retained.map(\.id), ["keep"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep").path))
    }
}
