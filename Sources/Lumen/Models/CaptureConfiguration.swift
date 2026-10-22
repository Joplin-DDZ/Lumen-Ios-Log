import Foundation

/// 控制台启动快照；用户点击「重启 App 并采集」后才创建，不继承旧设备日志模式。
struct CaptureConfiguration: Sendable {
    /// 已配对 iPhone 的设备标识。
    var deviceID: String
    /// 解析普通输出时使用的 App 名称。
    var process: String
    /// 要启动并接管 stdout/stderr 的 App Bundle ID。
    var bundleID: String
    /// 当前会话原始日志的保存目录。
    var folder: URL
    var maxBytes: Int = 256 * 1024 * 1024
}
