import AppKit

/// 原生日志列表支持标准复制快捷键，复制完整消息而不是屏幕截断摘要。
final class LogNativeTable: NSTableView {
    var copyLogs: (() -> Void)?
    /// AppKit 拖选使用嵌套事件循环，期间不能替换行数据或重建单元格。
    private(set) var isSelectingLogs = false
    var selectionGestureEnded: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        isSelectingLogs = true
        defer { isSelectingLogs = false; selectionGestureEnded?() }
        super.mouseDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            copyLogs?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
