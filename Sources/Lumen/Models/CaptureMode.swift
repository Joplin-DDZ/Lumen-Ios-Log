import Foundation

/// device 仅用于解码旧版历史元数据，新采集始终使用 App 标准输出。
enum CaptureMode: String, Codable, Sendable {
    case device, console
    var title: String { self == .device ? "旧设备日志" : "App 控制台" }
}
