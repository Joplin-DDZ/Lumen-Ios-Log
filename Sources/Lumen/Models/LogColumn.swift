import Foundation

/// 列标识同时用于原生表格和偏好存储，标题变化不影响已保存的显示设置。
enum LogColumn: String, CaseIterable, Identifiable {
    case id, clock, level, process, message
    var id: String { rawValue }
    var title: String {
        switch self {
        case .id: return "#"
        case .clock: return "时间"
        case .level: return "级别"
        case .process: return "进程 / 分类"
        case .message: return "消息"
        }
    }
}
