import XCTest
@testable import Lumen

final class LogMessageLayoutTests: XCTestCase {
    /// 明确的换行不能被原来的单行或三行摘要高度吞掉。
    func testAllExplicitLinesReceiveSpace() {
        let message = (1...24).map { "第\($0)行中文日志" }.joined(separator: "\n")
        let height = LogMessageLayout.rowHeight(message: message, columnWidth: 600, fontSize: 12)
        XCTAssertGreaterThan(height, 24 * 12)
    }

    /// 无空格的长 URL/JSON 值也应换行，1,500 字符之后仍需要真实的布局空间。
    func testLongUnbrokenMessageIsNotCappedAndReflowsWithWidth() {
        let message = String(repeating: "ABC123", count: 700) + "尾部仍应可见"
        let wide = LogMessageLayout.rowHeight(message: message, columnWidth: 800, fontSize: 12)
        let narrow = LogMessageLayout.rowHeight(message: message, columnWidth: 300, fontSize: 12)
        let prefix = LogMessageLayout.rowHeight(message: String(message.prefix(1500)), columnWidth: 800, fontSize: 12)
        XCTAssertGreaterThan(narrow, wide)
        XCTAssertGreaterThan(wide, prefix * 2)
    }

    func testLargerFontAndTrailingNewlineReceiveMoreSpace() {
        let message = String(repeating: "中文文字", count: 100)
        XCTAssertGreaterThan(LogMessageLayout.rowHeight(message: message, columnWidth: 400, fontSize: 18), LogMessageLayout.rowHeight(message: message, columnWidth: 400, fontSize: 10))
        XCTAssertGreaterThan(LogMessageLayout.rowHeight(message: "一行\n", columnWidth: 400, fontSize: 12), LogMessageLayout.rowHeight(message: "一行", columnWidth: 400, fontSize: 12))
    }
}
