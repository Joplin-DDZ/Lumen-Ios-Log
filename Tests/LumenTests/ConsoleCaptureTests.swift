import XCTest
@testable import Lumen

final class ConsoleCaptureTests: XCTestCase {
    /// 入口必须与旧设备日志偏好完全解耦，且隐藏工具连接状态输出。
    func testCommandAlwaysLaunchesAppConsole() {
        let config = CaptureConfiguration(deviceID: "phone", process: "App", bundleID: "com.example.app", folder: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(ConsoleCommand.arguments(for: config), ["devicectl", "device", "process", "launch", "--device", "phone", "--quiet", "--console", "--terminate-existing", "com.example.app"])
    }

    /// 模拟 App 同时大量写双管道并立即退出，结束事件必须晚于全部原始字节及尾部记录。
    func testConsoleDrainsBothStreamsBeforeFinishing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let expected = String(repeating: "中文业务日志🙂\n", count: 10000)
        let outFixture = folder.appendingPathComponent("out.txt"), errFixture = folder.appendingPathComponent("err.txt")
        try Data(expected.utf8).write(to: outFixture)
        try Data("标准错误尾部中文\n".utf8).write(to: errFixture)
        let service = CaptureService { _ in
            let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sh")
            child.arguments = ["-c", "cat \"$1\"; cat \"$2\" >&2", "lumen-test", outFixture.path, errFixture.path]
            return child
        }
        let probe = CaptureProbe()
        service.start(CaptureConfiguration(deviceID: "phone", process: "App", bundleID: "test.app", folder: folder)) { probe.accept($0) }
        for _ in 0..<200 { if probe.snapshot().finished { break }; try await Task.sleep(for: .milliseconds(25)) }
        defer { service.stop() }
        let result = probe.snapshot()
        XCTAssertTrue(result.finished); XCTAssertNil(result.error)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("stdout.log"), encoding: .utf8), expected)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("stderr.log"), encoding: .utf8), "标准错误尾部中文\n")
        XCTAssertTrue(result.records.contains { $0.source == .stderr && $0.raw == "标准错误尾部中文" })
        XCTAssertEqual(result.records.filter { $0.source == .stdout }.count, 10000)
    }

    func testOldDeviceSessionsStayOffConsoleWorkspaceWithoutDeletingMetadata() throws {
        var old = LogSession(id: "old", title: "App", deviceName: "iPhone", process: "App", mode: .device, createdAt: Date(), count: 1, status: "已保存")
        XCTAssertFalse(old.isConsoleVisible)
        old.mode = .console; XCTAssertTrue(old.isConsoleVisible)
        old.mode = .device; old.status = "已导入"; XCTAssertTrue(old.isConsoleVisible)
        XCTAssertEqual(old.sourceTitle, "本地文件")
        let legacy = try JSONDecoder().decode(LogSession.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(legacy.mode, .device)
    }
}
