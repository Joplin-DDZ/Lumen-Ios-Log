import Foundation

/// 标识始终使用硬件 UDID，禁止把 CoreDevice 标识传给 libimobiledevice。
struct DeviceInfo: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var version: String
    var model: String
    var connected: Bool
}
