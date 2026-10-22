import AppKit
import XCTest
@testable import Lumen

final class LogSelectionTests: XCTestCase {
    private func record(_ id: Int64, _ text: String) -> LogRecord {
        LogRecord(id: id, timestamp: Date(), clock: "", level: .info, process: "", category: "", message: text, raw: text, source: .stdout)
    }

    /// 即便数据库快照先到达，拖选也必须按屏幕上的旧快照解析 ID 和正文。
    @MainActor func testSelectionUsesDisplayedSnapshotAndPausesFollowing() {
        let model = AppModel()
        let displayed = [record(10, "原文十"), record(11, "原文十一")]
        model.rows = [record(11, "续写后十一"), record(12, "新日志")]
        model.selectRecords([10, 11], displayedRecords: displayed)
        XCTAssertEqual(model.selectedIDs, [10, 11])
        XCTAssertEqual(model.selectedCopyText, "原文十\n原文十一")
        XCTAssertFalse(model.autoScroll)
        model.rows = [record(100, "另一页")]
        XCTAssertEqual(model.selectedCopyText, "原文十\n原文十一")
        model.selectRecords([])
        XCTAssertEqual(model.selectedCopyText, "")
    }

    /// 删除前面的行或页面滑动后，选中状态应跟随 ID 而不是原行号。
    @MainActor func testReloadRestoresSelectionByID() {
        let model = AppModel()
        let coordinator = LogTableView.Coordinator(model: model)
        let table = LogNativeTable()
        table.delegate = coordinator; table.dataSource = coordinator
        coordinator.table = table
        coordinator.records = [record(10, "十"), record(11, "十一"), record(12, "十二")]
        model.selectRecords([11], displayedRecords: coordinator.records)
        coordinator.reload(preserving: nil)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))
        coordinator.records = [record(11, "十一续写"), record(12, "十二"), record(13, "十三")]
        coordinator.reload(preserving: nil)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 0))
        XCTAssertEqual(model.selectedIDs, [11])
        XCTAssertEqual(model.selectedCopyText, "十一")
    }
}
