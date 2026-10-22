import AppKit
import SwiftUI

/// NSTableView 虚拟化可见单元格，界面只持有一页记录，大会话查询交给 SQLite。
struct LogTableView: NSViewRepresentable {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(), table = LogNativeTable()
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.backgroundColor = .clear; table.gridStyleMask = []; table.intercellSpacing = .zero
        table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        table.selectionHighlightStyle = .regular; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowSizeStyle = .custom; table.rowHeight = 29
        // 时间与级别采用紧凑列宽，为完整消息留出更多阅读空间。
        let columns: [(String, String, CGFloat, CGFloat)] = [
            ("id", "#", 42, 36), ("clock", "时间", 104, 100),
            ("level", "级别", 58, 56), ("process", "进程 / 分类", 118, 85), ("message", "消息", 480, 190)
        ]
        for (id, title, width, minimum) in columns {
            let column = NSTableColumn(identifier: .init(id)); column.title = LogColumn(rawValue: id)?.title ?? title
            column.isHidden = model.hiddenColumns.contains(id)
            column.width = width; column.minWidth = minimum
            column.resizingMask = id == "message" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            column.headerCell.attributedStringValue = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
            table.addTableColumn(column)
        }
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        table.copyLogs = { [weak model] in model?.copySelection() }
        table.selectionGestureEnded = { [weak model] in
            // 松开鼠标后统一应用最新快照，采集和数据库写入始终继续。
            model?.tableVersion += 1
        }
        let menu = NSMenu()
        let copy = NSMenuItem(title: "复制完整日志", action: #selector(Coordinator.copyLogs), keyEquivalent: "")
        copy.target = context.coordinator; menu.addItem(copy)
        let surrounding = NSMenuItem(title: "查看上下文", action: #selector(Coordinator.showContext), keyEquivalent: "")
        surrounding.target = context.coordinator; menu.addItem(surrounding)
        menu.delegate = context.coordinator; table.menu = menu
        context.coordinator.table = table
        scroll.postsFrameChangedNotifications = true
        context.coordinator.resizeObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak coordinator = context.coordinator] _ in
            Task { @MainActor in coordinator?.scheduleWidthRefresh() }
        }
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak model, weak scroll, weak table] _ in
            Task { @MainActor in
                guard let scroll, let table, let model else { return }
                if scroll.documentVisibleRect.maxY < table.bounds.height - table.rowHeight * 2 { model.autoScroll = false }
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        guard (table as? LogNativeTable)?.isSelectingLogs != true else { return }
        let coordinator = context.coordinator
        scroll.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let columnsChanged = table.tableColumns.contains { $0.isHidden != model.hiddenColumns.contains($0.identifier.rawValue) }
        let needsReload = columnsChanged || coordinator.version != model.tableVersion || coordinator.fontSize != model.fontSize || coordinator.search != model.searchText || coordinator.scheme != scheme
        let anchor = coordinator.viewportAnchor()
        // 隐藏保留列对象与宽度，重新勾选后恢复；正文宽度改变需同步重算行高。
        if columnsChanged {
            coordinator.updating = true
            for column in table.tableColumns { column.isHidden = model.hiddenColumns.contains(column.identifier.rawValue) }
            table.sizeToFit()
            coordinator.updating = false
        }
        coordinator.records = model.rows; coordinator.fontSize = model.fontSize
        coordinator.search = model.searchText; coordinator.scheme = scheme
        if needsReload {
            coordinator.version = model.tableVersion
            let visibleIDs = Set(model.rows.map(\.id))
            coordinator.heights = coordinator.heights.filter { visibleIDs.contains($0.key) }
            coordinator.reload(preserving: anchor)
        }
        let indexes = IndexSet(model.rows.enumerated().filter { model.selectedIDs.contains($0.element.id) }.map(\.offset))
        if indexes != table.selectedRowIndexes {
            coordinator.updating = true; table.selectRowIndexes(indexes, byExtendingSelection: false); coordinator.updating = false
        }
        if model.autoScroll, model.viewingLive, !model.rows.isEmpty {
            table.scrollRowToVisible(model.rows.count - 1)
        } else if let target = model.scrollTarget, target != coordinator.lastScrollTarget,
                  let index = model.rows.firstIndex(where: { $0.id == target }) {
            table.scrollRowToVisible(index); coordinator.lastScrollTarget = target
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: AppModel
        weak var table: NSTableView?
        var records: [LogRecord] = []
        var version = -1
        var fontSize: Double = 12
        /// 缓存以记录内容、列宽和字号校验；流式续写只重算发生变化的消息。
        var heights: [Int64: (message: String, width: CGFloat, fontSize: Double, height: CGFloat)] = [:]
        var lastLayoutWidth: CGFloat = 0
        var widthRefreshScheduled = false
        var search = ""
        var scheme = ColorScheme.light
        var updating = false
        var lastScrollTarget: Int64?
        var scrollObserver: NSObjectProtocol?
        var resizeObserver: NSObjectProtocol?
        init(model: AppModel) { self.model = model }
        deinit {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard records.indices.contains(row), let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == "message" }), !column.isHidden else { return CGFloat(fontSize + 17) }
            let record = records[row], width = column.width
            if let cached = heights[record.id], cached.message == record.message, cached.width == width, cached.fontSize == fontSize { return cached.height }
            let height = LogMessageLayout.rowHeight(message: record.message, columnWidth: width, fontSize: fontSize)
            heights[record.id] = (record.message, width, fontSize, height)
            return height
        }

        /// 调整窗口、详情栏或表头列宽后，按新的正文宽度重新排版。
        func tableViewColumnDidResize(_ notification: Notification) { scheduleWidthRefresh() }
        func scheduleWidthRefresh() {
            guard (table as? LogNativeTable)?.isSelectingLogs != true else { return }
            guard !widthRefreshScheduled else { return }
            widthRefreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.widthRefreshScheduled = false
                guard let width = self.table?.tableColumns.first(where: { $0.identifier.rawValue == "message" })?.width,
                      abs(width - self.lastLayoutWidth) > 0.5 else { return }
                self.reload(preserving: self.viewportAnchor())
                if self.model.autoScroll, self.model.viewingLive, !self.records.isEmpty { self.table?.scrollRowToVisible(self.records.count - 1) }
            }
        }

        /// 保存当前第一条可见记录及行内偏移，排版变化不把阅读位置跳回顶部。
        func viewportAnchor() -> (id: Int64, offset: CGFloat)? {
            guard let table, let clip = table.enclosingScrollView?.contentView else { return nil }
            let row = table.row(at: NSPoint(x: 0, y: clip.bounds.minY))
            guard records.indices.contains(row) else { return nil }
            return (records[row].id, clip.bounds.minY - table.rect(ofRow: row).minY)
        }

        func reload(preserving anchor: (id: Int64, offset: CGFloat)?) {
            guard let table else { return }
            updating = true
            table.rowHeight = CGFloat(fontSize + 17)
            lastLayoutWidth = table.tableColumns.first(where: { $0.identifier.rawValue == "message" })?.width ?? 0
            table.reloadData()
            // reloadData 保留的是行号，必须在同一更新事务内按日志 ID 恢复选择。
            let indexes = IndexSet(records.indices.filter { model.selectedIDs.contains(records[$0].id) })
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            if let anchor, let row = records.firstIndex(where: { $0.id == anchor.id }), let scroll = table.enclosingScrollView {
                let clip = scroll.contentView
                // 隐藏正文会大幅缩短行高，旧行内偏移不得把视口推到内容之外。
                let contentHeight = records.isEmpty ? 0 : table.rect(ofRow: records.count - 1).maxY
                let proposedY = table.rect(ofRow: row).minY + min(anchor.offset, table.rect(ofRow: row).height)
                let y = max(0, min(proposedY, max(0, contentHeight - clip.bounds.height)))
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
                scroll.reflectScrolledClipView(clip)
            }
            updating = false
        }

        func numberOfRows(in tableView: NSTableView) -> Int { records.count }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { LogRowView() }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < records.count, let column = tableColumn else { return nil }
            let record = records[row], identifier = column.identifier
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? makeCell(identifier)
            guard let text = cell.textField else { return cell }
            var value = "", color = NSColor.labelColor
            var font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            switch identifier.rawValue {
            case "id": value = String(record.id); color = .tertiaryLabelColor; font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            case "clock": value = record.clock; color = .secondaryLabelColor; font = .monospacedSystemFont(ofSize: max(10, fontSize - 1), weight: .regular)
            case "level": value = record.level.title; color = levelColor(record.level); font = .monospacedSystemFont(ofSize: 9, weight: .medium)
            case "process": value = record.category.isEmpty ? record.process : record.category; color = .secondaryLabelColor; font = .systemFont(ofSize: max(10, fontSize - 1))
            default: value = record.message
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if identifier.rawValue == "message" { attributes.merge(LogMessageLayout.attributes(fontSize: fontSize)) { _, new in new } }
            let attributed = NSMutableAttributedString(string: value, attributes: attributes)
            if !search.isEmpty, identifier.rawValue == "message" {
                let string = value as NSString
                var range = NSRange(location: 0, length: string.length)
                while range.length > 0 {
                    let match = string.range(of: search, options: .caseInsensitive, range: range)
                    guard match.location != NSNotFound else { break }
                    attributed.addAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.25)], range: match)
                    range = NSRange(location: match.upperBound, length: string.length - match.upperBound)
                }
            }
            text.attributedStringValue = attributed
            let isMessage = identifier.rawValue == "message"
            text.usesSingleLineMode = !isMessage
            text.maximumNumberOfLines = isMessage ? 0 : 1
            text.lineBreakMode = isMessage ? .byCharWrapping : .byTruncatingTail
            text.preferredMaxLayoutWidth = isMessage ? max(1, column.width - 15) : 0
            if let textCell = text.cell as? NSTextFieldCell {
                textCell.wraps = isMessage; textCell.isScrollable = !isMessage
            }
            cell.toolTip = identifier.rawValue == "message" ? String(record.message.prefix(1000)) : value
            cell.setAccessibilityLabel("\(column.title)：\(value)")
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            model.selectRecords(Set(table.selectedRowIndexes.compactMap { records.indices.contains($0) ? records[$0].id : nil }), displayedRecords: records)
        }
        func menuWillOpen(_ menu: NSMenu) {
            guard let table else { return }
            if table.clickedRow >= 0, !table.selectedRowIndexes.contains(table.clickedRow) { table.selectRowIndexes([table.clickedRow], byExtendingSelection: false) }
        }
        @objc func copyLogs() { model.copySelection() }
        @objc func showContext() { model.showContext() }

        private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView(); cell.identifier = identifier
            let text = NSTextField(labelWithString: ""); text.translatesAutoresizingMaskIntoConstraints = false
            text.isSelectable = false; text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.addSubview(text); cell.textField = text
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -7), text.topAnchor.constraint(equalTo: cell.topAnchor, constant: 7), text.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -4)])
            return cell
        }
        private func levelColor(_ level: LogLevel) -> NSColor {
            switch level {
            case .debug: return .secondaryLabelColor
            case .info: return .systemBlue
            case .notice: return .systemTeal
            case .warning: return .systemOrange
            case .error: return .systemRed
            case .fault: return .systemPurple
            }
        }
    }
}
