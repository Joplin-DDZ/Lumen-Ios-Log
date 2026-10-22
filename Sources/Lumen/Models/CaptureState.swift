import Foundation

/// 控制台断开后结束归档；不通过后台重启 App 伪装成自动重连。
enum CaptureState: Equatable {
    case idle, starting, recording, stopping
    var isActive: Bool { self != .idle }
    var title: String {
        switch self {
        case .idle: return "准备就绪"
        case .starting: return "正在连接"
        case .recording: return "正在采集"
        case .stopping: return "正在保存"
        }
    }
}
