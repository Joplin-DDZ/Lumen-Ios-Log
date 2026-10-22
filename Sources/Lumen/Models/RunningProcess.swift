import Foundation

/// 运行进程与安装包分开建模，兼容没有 Bundle ID 的系统进程。
struct RunningProcess: Identifiable, Equatable, Sendable {
    var id: Int
    var name: String
}
