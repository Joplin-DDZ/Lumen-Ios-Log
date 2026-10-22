import Foundation

/// 只接管目标 App 的标准流；quiet 抑制设备隧道等工具状态，不启用系统日志通道。
struct ConsoleCommand {
    static func makeProcess(_ config: CaptureConfiguration) throws -> Process {
        guard let tool = ToolLocator.find("xcrun") else {
            throw NSError(domain: "Lumen.Console", code: 1, userInfo: [NSLocalizedDescriptionKey: "读取 App 控制台需要安装并选择完整 Xcode。"])
        }
        let child = Process()
        child.executableURL = tool
        // 已运行的进程无法补接 print；界面用明确的重启按钮取得本次操作意图。
        child.arguments = arguments(for: config)
        return child
    }

    static func arguments(for config: CaptureConfiguration) -> [String] {
        ["devicectl", "device", "process", "launch", "--device", config.deviceID,
         "--quiet", "--console", "--terminate-existing", config.bundleID]
    }
}
