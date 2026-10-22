import AppKit

/// 退出前等待采集尾部记录保存；关闭窗口不会误杀 iPhone 上的目标 App。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.windows.first { $0.title == "Lumen" }?.makeKeyAndOrderFront(nil)
        return true
    }
}
