import Foundation

/// 会话按创建时间保留最新 100 份，支持主动删除；设备断开、清空视图或筛选不删除会话。
struct LogSession: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var deviceName: String
    var process: String
    var mode: CaptureMode
    var createdAt: Date
    var count: Int
    var status: String

    /// 兼容读取旧数据库，但工作区只展示 App 控制台和用户主动导入的文件。
    var isConsoleVisible: Bool { mode == .console || status == "已导入" }
    var sourceTitle: String { status == "已导入" ? "本地文件" : mode.title }
}
