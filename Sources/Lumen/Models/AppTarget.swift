import Foundation

/// 已安装开发 App 的显示信息；可执行文件名用于设备日志过滤。
struct AppTarget: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var executable: String
    var version: String
}
