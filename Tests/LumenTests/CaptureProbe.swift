import Foundation
@testable import Lumen

/// 回调运行于读取器队列，测试通过锁获取一致的结束快照。
final class CaptureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LogRecord] = []
    private var finished = false
    private var error: String?

    func accept(_ event: CaptureEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .records(let records): values += records
        case .finished(let message): finished = true; error = message
        case .started: break
        }
    }
    func snapshot() -> (records: [LogRecord], finished: Bool, error: String?) {
        lock.lock(); defer { lock.unlock() }
        return (values, finished, error)
    }
}
