import Foundation

/// GUI 应用不继承交互式 shell PATH，显式检查常见安装位置。
enum ToolLocator {
    static func find(_ name: String) -> URL? {
        let folders = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        return folders.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
