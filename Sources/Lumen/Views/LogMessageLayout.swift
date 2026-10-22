import AppKit

/// 列表与测量共用字体和换行规则，长 URL、JSON 和多行消息都不做摘要截断。
enum LogMessageLayout {
    /// 单元格外边距 15 pt，加上 NSTextField 文本区域内边距 4 pt。
    static let horizontalInset: CGFloat = 19
    static let verticalInset: CGFloat = 16

    static func attributes(fontSize: Double) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        return [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular), .paragraphStyle: paragraph]
    }

    /// 按实际列宽排版全部字符，不限制行数；尾部空行也计入高度。
    static func rowHeight(message: String, columnWidth: CGFloat, fontSize: Double) -> CGFloat {
        let storage = NSTextStorage(string: message, attributes: attributes(fontSize: fontSize))
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(1, columnWidth - horizontalInset), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byCharWrapping
        container.maximumNumberOfLines = 0
        layout.addTextContainer(container); storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let textHeight = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        return max(CGFloat(fontSize + 17), ceil(textHeight) + verticalInset)
    }
}
