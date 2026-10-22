import XCTest
@testable import Lumen

final class ParserTests: XCTestCase {
    /// 模拟 USB 在中文每一个字节边界分包，必须逐字还原。
    func testUTF8SplitAtEveryByte() {
        let data = Data("中文日志🙂\r\n第二行\n尾部".utf8)
        for split in 0...data.count {
            var decoder = UTF8LineDecoder()
            let lines = decoder.feed(data.prefix(split)) + decoder.feed(data.dropFirst(split), final: true)
            XCTAssertEqual(lines, ["中文日志🙂", "第二行", "尾部"])
        }
    }
    func testOversizedUnterminatedLinePreservesChinese() {
        let text = String(repeating: "中文", count: 100000)
        var decoder = UTF8LineDecoder()
        let lines = decoder.feed(Data(text.utf8), final: true)
        XCTAssertEqual(lines.joined(), text)
        XCTAssertGreaterThan(lines.count, 1)
    }
    func testDeviceRecordAndContinuationKeepIdentityAcrossDrain() {
        var id: Int64 = 0
        let parser = LogParser(source: .device, process: "App", nextID: { id += 1; return id })
        parser.consume("Oct 21 16:26:32.278774 looiRobot(CoreFoundation)[15800] <Notice>: 中文测试")
        let first = parser.drain()
        XCTAssertEqual(first.count, 1); XCTAssertEqual(first[0].process, "looiRobot")
        XCTAssertEqual(first[0].category, "CoreFoundation"); XCTAssertEqual(first[0].level, .notice)
        parser.consume("第二行 {\"ok\":true}")
        let second = parser.drain()
        XCTAssertEqual(second[0].id, first[0].id)
        XCTAssertEqual(second[0].message, "中文测试\n第二行 {\"ok\":true}")
    }
    func testKMPNetworkBodyAndNextBusinessRecord() {
        var id: Int64 = 0
        let parser = LogParser(source: .stdout, process: "looiRobot", nextID: { id += 1; return id })
        ["KMP[D][网络请求] 请求开始", "BODY START", "{\"hello\":\"中文\"}", "BODY END",
         "2026-10-21 16:05:59.186 [Main] error user - 蓝牙连接失败"].forEach(parser.consume)
        let records = parser.drain()
        XCTAssertEqual(records.count, 2); XCTAssertEqual(records[0].level, .debug)
        XCTAssertEqual(records[0].category, "网络请求"); XCTAssertTrue(records[0].message.contains("BODY END"))
        XCTAssertEqual(records[1].level, .error); XCTAssertEqual(records[1].message, "蓝牙连接失败")
    }
    /// App 的普通 NSLog 必须从 KMP 消息体中独立出来，原始内容完整保留。
    func testNSLogStartsNewRecordAfterKMP() {
        var id: Int64 = 0
        let parser = LogParser(source: .stderr, process: "App", nextID: { id += 1; return id })
        parser.consume("KMP[D][网络] BODY START")
        parser.consume("{\"ok\":true}")
        parser.consume("2026-10-22 10:20:30.123+0800 App[123:456] 自己的 NSLog 中文")
        parser.consume("第二行")
        let records = parser.drain()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[1].message, "自己的 NSLog 中文\n第二行")
        XCTAssertEqual(records[1].source, .stderr)
    }
    func testStderrDoesNotImplyError() {
        var id: Int64 = 0
        let parser = LogParser(source: .stderr, process: "App", nextID: { id += 1; return id })
        parser.consume("普通标准错误输出")
        let record = parser.drain()[0]
        XCTAssertEqual(record.level, .info); XCTAssertEqual(record.source, .stderr)
    }
    func testFormattingExtractsJSONObjectWithoutChangingRaw() {
        XCTAssertTrue(JSONFormatting.pretty("BODY START\n{\"中文\":true}\nBODY END")?.contains("中文") == true)
        XCTAssertNil(JSONFormatting.pretty("错误 {not-json}"))
        XCTAssertNotNil(JSONFormatting.pretty("[1,2,3]"))
    }
    func testInvalidRegexIsRejected() {
        XCTAssertNotNil(LogFilter(include: "[", regex: true).validationError)
        XCTAssertNil(LogFilter(include: "蓝牙|LLM", regex: true).validationError)
    }
}
