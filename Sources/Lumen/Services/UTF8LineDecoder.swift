import Foundation

/// 按行缓冲字节，避免 USB 读取切在 UTF-8 中文字符中间时产生乱码。
struct UTF8LineDecoder {
    private var buffer = Data()
    mutating func feed(_ data: Data, final: Bool = false) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 10) {
            lines.append(String(decoding: buffer[..<newline], as: UTF8.self).trimmingCharacters(in: .init(charactersIn: "\r")))
            buffer.removeSubrange(...newline)
        }
        // 无换行的超长 SDK 输出也要有界；按完整 UTF-8 边界分段，磁盘原始流保持完整。
        while buffer.count > 512 * 1024 {
            let bytes = Array(buffer.prefix(256 * 1024 + 4))
            var end = 256 * 1024
            while end > 0 && bytes[end] & 0xC0 == 0x80 { end -= 1 }
            lines.append(String(decoding: buffer.prefix(end), as: UTF8.self))
            buffer.removeFirst(end)
        }
        if final, !buffer.isEmpty {
            lines.append(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll(keepingCapacity: false)
        }
        return lines
    }
}
