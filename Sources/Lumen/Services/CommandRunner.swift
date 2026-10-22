import Foundation

/// 只执行短时查询命令；设备命令有超时，标准流并行消费，防止管道写满死锁。
enum CommandRunner {
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 12) async throws -> (String, String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let process = Process(), out = Pipe(), err = Pipe()
                    process.executableURL = executable; process.arguments = arguments
                    process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
                    let finished = DispatchSemaphore(value: 0)
                    process.terminationHandler = { _ in finished.signal() }
                    try process.run()
                    let readers = DispatchGroup(), lock = NSLock()
                    var stdout = Data(), stderr = Data()
                    readers.enter()
                    DispatchQueue.global(qos: .utility).async {
                        let data = out.fileHandleForReading.readDataToEndOfFile()
                        lock.lock(); stdout = data; lock.unlock(); readers.leave()
                    }
                    readers.enter()
                    DispatchQueue.global(qos: .utility).async {
                        let data = err.fileHandleForReading.readDataToEndOfFile()
                        lock.lock(); stderr = data; lock.unlock(); readers.leave()
                    }
                    let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
                    if timedOut { process.terminate(); if finished.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) } }
                    readers.wait()
                    lock.lock(); let output = String(decoding: stdout, as: UTF8.self), errorText = String(decoding: stderr, as: UTF8.self); lock.unlock()
                    if timedOut { throw NSError(domain: "Lumen.Device", code: 1, userInfo: [NSLocalizedDescriptionKey: "设备响应超时，请解锁 iPhone 并检查连接。"])}
                    guard process.terminationStatus == 0 else {
                        throw NSError(domain: "Lumen.Device", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String((errorText.isEmpty ? output : errorText).prefix(1200))])
                    }
                    continuation.resume(returning: (output, errorText))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
