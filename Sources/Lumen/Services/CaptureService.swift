import Foundation

/// 独立串行队列处理字节、解析和原始写盘；Process 始终仅管理本次创建的读取器。
final class CaptureService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.lumen.capture", qos: .userInitiated)
    private var process: Process?
    private var stdout: Pipe?
    private var stderr: Pipe?
    private var outFile: FileHandle?
    private var errFile: FileHandle?
    private var outDecoder = UTF8LineDecoder()
    private var errDecoder = UTF8LineDecoder()
    private var outParser: LogParser?
    private var errParser: LogParser?
    private var timer: DispatchSourceTimer?
    private var sequence: Int64 = 0
    private var bytes = 0
    private var limit = 0
    private var token = UUID()
    private var stopping = false
    private var failure: String?
    private let makeProcess: @Sendable (CaptureConfiguration) throws -> Process
    /// 读取结束必须等到双管道 EOF，避免固定延时关闭造成尾部业务日志丢失。
    private var stdoutEnded = false
    private var stderrEnded = false
    private var exitStatus: Int32?

    init(makeProcess: @escaping @Sendable (CaptureConfiguration) throws -> Process = { try ConsoleCommand.makeProcess($0) }) {
        self.makeProcess = makeProcess
    }
    private var completion: (@Sendable (CaptureEvent) -> Void)?

    func start(_ config: CaptureConfiguration, callback: @escaping @Sendable (CaptureEvent) -> Void) {
        queue.async { [self] in
            guard process == nil else { callback(.finished("已有采集任务正在运行。")); return }
            token = UUID(); let currentToken = token
            sequence = 0; bytes = 0; limit = config.maxBytes; stopping = false; failure = nil
            completion = callback; stdoutEnded = false; stderrEnded = false; exitStatus = nil
            outDecoder = UTF8LineDecoder(); errDecoder = UTF8LineDecoder()
            outParser = LogParser(source: .stdout, process: config.process, nextID: { [weak self] in self?.nextID() ?? 0 })
            errParser = LogParser(source: .stderr, process: config.process, nextID: { [weak self] in self?.nextID() ?? 0 })
            do {
                let child = try makeProcess(config), out = Pipe(), err = Pipe()
                for name in ["stdout.log", "stderr.log"] {
                    let path = config.folder.appendingPathComponent(name).path
                    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
                    bytes += (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                }
                outFile = try FileHandle(forWritingTo: config.folder.appendingPathComponent("stdout.log"))
                errFile = try FileHandle(forWritingTo: config.folder.appendingPathComponent("stderr.log"))
                try outFile?.seekToEnd(); try errFile?.seekToEnd()
                child.standardOutput = out; child.standardError = err; child.standardInput = FileHandle.nullDevice
                process = child; stdout = out; stderr = err
                out.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil }
                    self?.queue.async { [weak self] in self?.receive(data, isError: false, token: currentToken) }
                }
                err.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil }
                    self?.queue.async { [weak self] in self?.receive(data, isError: true, token: currentToken) }
                }
                child.terminationHandler = { [weak self] task in
                    self?.queue.async { [weak self] in
                        guard let self, self.token == currentToken else { return }
                        self.exitStatus = task.terminationStatus
                        self.finishIfDrained(token: currentToken)
                    }
                }
                try child.run()
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 0.15, repeating: 0.15)
                timer.setEventHandler { [weak self] in self?.flush() }; timer.resume(); self.timer = timer
                NSLog("[Lumen] App 控制台启动成功：进程=%@，接管 stdout/stderr", config.process)
                callback(.started)
            } catch {
                failure = error.localizedDescription
                cleanup(); callback(.finished(error.localizedDescription))
            }
        }
    }

    /// devicectl 必须 SIGKILL，避免普通信号被转发并结束目标 App。
    func stop() { queue.async { [weak self] in self?.stopOnQueue() } }

    private func stopOnQueue() {
        guard let process, process.isRunning, !stopping else { return }
        stopping = true
        kill(process.processIdentifier, SIGKILL)
    }

    private func receive(_ data: Data, isError: Bool, token currentToken: UUID) {
        guard currentToken == token, process != nil else { return }
        if data.isEmpty {
            if isError { stderrEnded = true } else { stdoutEnded = true }
            finishIfDrained(token: currentToken)
            return
        }
        do {
            let remaining = max(0, limit - bytes)
            let accepted = data.prefix(remaining)
            try (isError ? errFile : outFile)?.write(contentsOf: accepted)
            bytes += accepted.count
            let lines = isError ? errDecoder.feed(accepted) : outDecoder.feed(accepted)
            for line in lines { (isError ? errParser : outParser)?.consume(line) }
            if bytes >= limit {
                failure = "本次采集已达到 256 MB 容量上限，日志已保存。请开始新的会话。"
                NSLog("[Lumen] 采集达到容量上限，自动停止"); stopOnQueue()
            }
        } catch {
            failure = "原始日志写入失败：\(error.localizedDescription)"; NSLog("[Lumen] 原始日志写入异常"); stopOnQueue()
        }
    }
    private func nextID() -> Int64 { sequence += 1; return sequence }
    private func flush() {
        let records = ((outParser?.drain() ?? []) + (errParser?.drain() ?? [])).sorted { $0.id < $1.id }
        if !records.isEmpty { completion?(.records(records)) }
    }
    private func finishIfDrained(token currentToken: UUID) {
        guard currentToken == token, process != nil, stdoutEnded, stderrEnded, let status = exitStatus else { return }
        for line in outDecoder.feed(Data(), final: true) { outParser?.consume(line) }
        for line in errDecoder.feed(Data(), final: true) { errParser?.consume(line) }
        flush()
        let message = failure ?? (!stopping && status != 0 ? "采集进程已退出（\(status)）。请检查设备信任、开发者模式和 App 信息；错误输出已保存到会话。" : nil)
        let callback = completion
        NSLog("[Lumen] 采集结束：退出码=%d 主动停止=%@", status, stopping ? "是" : "否")
        cleanup(); callback?(.finished(message))
    }
    private func cleanup() {
        timer?.cancel(); timer = nil
        stdout?.fileHandleForReading.readabilityHandler = nil; stderr?.fileHandleForReading.readabilityHandler = nil
        try? outFile?.synchronize(); try? errFile?.synchronize()
        try? outFile?.close(); try? errFile?.close()
        outFile = nil; errFile = nil; stdout = nil; stderr = nil; process = nil; completion = nil
    }
    private func error(_ text: String) -> NSError { NSError(domain: "Lumen.Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
