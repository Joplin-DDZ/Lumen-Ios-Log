import SwiftUI

/// 空状态不填充模拟日志，设备、采集与筛选状态均来自真实模型。
struct EmptyLogView: View {
    @ObservedObject var model: AppModel
    var configure: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 25).fill(LumenStyle.inset(scheme)).frame(width: 94, height: 108).rotationEffect(.degrees(-9)).offset(x: -16, y: -3)
                RoundedRectangle(cornerRadius: 25).fill(LumenStyle.surface(scheme))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.1 : 0.04), radius: 18, y: 9).frame(width: 94, height: 108).rotationEffect(.degrees(7)).offset(x: 12, y: 4)
                Image(systemName: model.filter.hasConditions ? "line.3.horizontal.decrease" : "waveform.path")
                    .font(.system(size: 36, weight: .light)).foregroundStyle(LumenStyle.accent(scheme)).offset(x: 4)
            }.frame(height: 140).padding(.bottom, 22)
            if model.filter.hasConditions || model.filter.afterID > 0 {
                Text("给线索，多一点空间。").font(.system(size: 27, weight: .semibold)).tracking(-0.9)
                Text(model.filter.afterID > 0 ? "视图已清空，新日志会继续出现。历史记录依然保留。" : "暂时没有匹配的日志。试试调整关键词或日志级别。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 12).multilineTextAlignment(.center)
                Button("显示全部日志") { model.filter = LogFilter() }.buttonStyle(PillButtonStyle()).padding(.top, 24)
            } else if model.state.isActive && model.viewingLive {
                Text("让线索，自然浮现。").font(.system(size: 29, weight: .semibold)).tracking(-1)
                Text("正在读取 App 的 print、业务日志和标准错误。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 12).multilineTextAlignment(.center)
                HStack(spacing: 6) { Circle().fill(.green).frame(width: 5, height: 5); Text(model.state.title).font(.system(size: 10)).foregroundStyle(.secondary) }.padding(.top, 25)
            } else if model.currentSession != nil {
                Text("这段记录，尚无日志。").font(.system(size: 27, weight: .semibold)).tracking(-0.9)
                Text("你可以重新开始采集，或导入已有的日志文件。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 12)
                Button("导入日志") { model.importFile() }.buttonStyle(PillButtonStyle()).padding(.top, 24)
            } else {
                Text("App 控制台，\n只看自己的日志。")
                    .font(.system(size: 37, weight: .semibold)).tracking(-1.5).multilineTextAlignment(.center).lineSpacing(1)
                Text("连接 iPhone，启动你的 App。\n在 Mac 上查看 print 和业务日志。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5).padding(.top, 16)
                Button(action: configure) {
                    HStack(spacing: 12) { Text("选择 App 并采集"); Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)) }
                }.buttonStyle(PillButtonStyle(primary: true)).padding(.top, 27)
            }
            Spacer()
            if model.currentSession == nil {
                HStack(spacing: 26) {
                    hint("cable.connector", "USB 真机")
                    hint("text.magnifyingglass", "即时搜索")
                    hint("internaldrive", "本地保存")
                }.padding(.bottom, 35)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 24)
    }
    private func hint(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 10)).foregroundStyle(.tertiary)
    }
}
