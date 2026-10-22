import Foundation

/// 采集层批量上送快照，结束事件在所有尾部记录之后交付。
enum CaptureEvent: Sendable {
    case started
    case records([LogRecord])
    case finished(String?)
}
