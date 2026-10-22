import SwiftUI

/// 原生 macOS 应用入口；主题覆盖窗口而非仅某一块内容，重启后恢复选择。
@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @AppStorage("appearanceMode") private var appearance = AppearanceMode.system.rawValue

    var body: some Scene {
        Window("Lumen", id: "main") {
            ContentView(model: model)
                .preferredColorScheme(AppearanceMode(rawValue: appearance)?.scheme)
                .task { delegate.model = model; await model.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建采集…") { NotificationCenter.default.post(name: .init("Lumen.NewCapture"), object: nil) }
                    .keyboardShortcut("n").disabled(model.state.isActive)
                Button("导入日志…") { model.importFile() }.keyboardShortcut("o").disabled(model.isImporting)
            }
            CommandMenu("日志") {
                Button("搜索日志") { NotificationCenter.default.post(name: .init("Lumen.FocusSearch"), object: nil) }.keyboardShortcut("f")
                Button("下一个匹配") { model.findNext(1) }.keyboardShortcut("g")
                Button("上一个匹配") { model.findNext(-1) }.keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button(model.autoScroll ? "暂停自动滚动" : "回到最新日志") {
                    if model.autoScroll { model.autoScroll = false } else { model.resumeScrolling() }
                }.keyboardShortcut("l")
                Button("清空视图（保留历史）") { model.clearView() }.keyboardShortcut("k")
                Button("复制选中的日志") { model.copySelection() }.disabled(model.selectedIDs.isEmpty)
                Divider()
                Button("导出整个会话…") { model.export(json: false, all: true) }.keyboardShortcut("e").disabled(model.selectedSessionID == nil)
                Button("停止采集") { model.stopCapture() }.keyboardShortcut(".").disabled(!model.state.isActive)
            }
            CommandMenu("外观") {
                ForEach(AppearanceMode.allCases) { mode in
                    Button { appearance = mode.rawValue } label: {
                        if appearance == mode.rawValue { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) }
                    }
                }
                Divider()
                Button("增大字号") { model.changeFontSize(1) }.keyboardShortcut("+")
                Button("减小字号") { model.changeFontSize(-1) }.keyboardShortcut("-")
                Toggle("显示日志详情", isOn: $model.showInspector)
            }
        }
    }
}
