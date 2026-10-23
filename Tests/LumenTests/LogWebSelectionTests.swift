import XCTest
import WebKit
@testable import Lumen

/// 在真实 WebKit 中核对浏览器选区、流式续写与日志文本隔离。
@MainActor final class LogWebSelectionTests: XCTestCase {
    private func page() async throws -> WKWebView {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view.loadHTMLString(LogWebDocument.html, baseURL: nil)
        for _ in 0..<200 {
            if (try? await view.evaluateJavaScript("typeof window.lumen === 'object'")) as? Bool == true { return view }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "HTML 日志页未就绪", code: 1)
    }

    private func update(_ view: WKWebView, messages: [String], context: String = "session", follow: Bool = false) async throws {
        let payload: [String: Any] = ["rows": messages.enumerated().map { index, text in
            ["id": String(index + 1), "clock": "12:00:00", "level": "INFO", "process": "Demo", "message": text, "raw": text]
        }, "hidden": ["id", "clock", "level", "process"], "font": 12, "dark": false, "search": "", "follow": follow, "target": "", "context": context]
        _ = try await view.callAsyncJavaScript("window.lumen.update(payload)", arguments: ["payload": payload], in: nil, contentWorld: .page)
    }

    func testCrossRecordSelectionSurvivesStreamingAndFlushesAfterClear() async throws {
        let view = try await page()
        try await update(view, messages: ["中文第一条\n第二行", "another record"])
        _ = try await view.evaluateJavaScript("""
        const cells=document.querySelectorAll('tbody td');
        const range=document.createRange();range.setStart(cells[0].firstChild,2);range.setEnd(cells[1].firstChild,7);
        getSelection().removeAllRanges();getSelection().addRange(range);
        """)
        let before = try await view.evaluateJavaScript("getSelection().toString()") as? String
        XCTAssertTrue(before?.contains("another") == true)
        try await update(view, messages: ["续写后的正文", "another record", "new record"])
        let after = try await view.evaluateJavaScript("getSelection().toString()") as? String
        XCTAssertEqual(before, after)
        let count = try await view.evaluateJavaScript("document.querySelectorAll('tbody tr').length") as? Int
        XCTAssertEqual(count, 2)
        _ = try await view.callAsyncJavaScript("getSelection().removeAllRanges(); await new Promise(r=>setTimeout(r,50));", contentWorld: .page)
        let finalCount = try await view.evaluateJavaScript("document.querySelectorAll('tbody tr').length") as? Int
        XCTAssertEqual(finalCount, 3)
    }

    func testLogMarkupRemainsTextAndClickDoesNotSelectOrHighlight() async throws {
        let view = try await page()
        let hostile = "<script>window.injected=true</script><img src='https://example.com/private'> & 中文"
        try await update(view, messages: [hostile])
        let value = try await view.evaluateJavaScript("document.querySelector('tbody td').textContent") as? String
        XCTAssertEqual(value, hostile)
        let safe = try await view.evaluateJavaScript("!window.injected && document.querySelectorAll('tbody script,tbody img').length===0") as? Bool
        XCTAssertEqual(safe, true)
        _ = try await view.evaluateJavaScript("document.querySelector('tbody td').click()")
        let collapsed = try await view.evaluateJavaScript("getSelection().isCollapsed && !document.querySelector('tr.chosen')") as? Bool
        XCTAssertEqual(collapsed, true)
    }

    func testSessionSwitchAndResumeExplicitlyReleaseSelection() async throws {
        let view = try await page()
        try await update(view, messages: ["old"], follow: true)
        _ = try await view.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('tbody'));getSelection().addRange(r);")
        try await update(view, messages: ["new"], context: "other")
        let reset = try await view.evaluateJavaScript("getSelection().isCollapsed && document.querySelector('tbody td').textContent==='new'") as? Bool
        XCTAssertEqual(reset, true)
        _ = try await view.evaluateJavaScript("const r2=document.createRange();r2.selectNodeContents(document.querySelector('tbody'));getSelection().addRange(r2);")
        try await update(view, messages: ["latest"], context: "other", follow: true)
        let resumed = try await view.evaluateJavaScript("getSelection().isCollapsed && document.querySelector('tbody td').textContent==='latest'") as? Bool
        XCTAssertEqual(resumed, true)
    }
}
