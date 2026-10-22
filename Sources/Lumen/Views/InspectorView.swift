import SwiftUI

/// 完整详情支持文本选择、JSON 格式化及取消筛选后查看同一条消息的上下文。
struct InspectorView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var formatted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("日志详情").font(.system(size: 12, weight: .semibold))
                Spacer()
                IconButton(symbol: "sidebar.right", label: "收起详情") { model.showInspector = false }
            }.padding(.horizontal, 18).padding(.vertical, 11)
            Rectangle().fill(LumenStyle.hairline(scheme)).frame(height: 1)
            if let record = model.selectedRecord {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { LevelBadge(level: record.level); Spacer(); Text("#\(record.id)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
                    Text(record.clock).font(.system(size: 23, weight: .light, design: .monospaced)).tracking(-1)
                    VStack(spacing: 9) {
                        property("进程", record.process)
                        if !record.category.isEmpty { property("分类", record.category) }
                        property("来源", record.source.rawValue)
                        property("长度", "\(record.raw.utf8.count.formatted()) bytes")
                    }
                    HStack(spacing: 6) {
                        Button("原始消息") { formatted = false }.foregroundStyle(!formatted ? .primary : .secondary)
                        Text("/").foregroundStyle(.quaternary)
                        Button("JSON") { formatted = true }.foregroundStyle(formatted ? .primary : .secondary).disabled(JSONFormatting.pretty(record.message) == nil)
                        Spacer()
                        IconButton(symbol: "doc.on.doc", label: "复制完整日志") { model.copySelection() }
                    }.buttonStyle(.plain).font(.system(size: 10, weight: .medium)).padding(.top, 5)
                }.padding(20)
                Rectangle().fill(LumenStyle.hairline(scheme)).frame(height: 1)
                ScrollView([.horizontal, .vertical]) {
                    Text(formatted ? JSONFormatting.pretty(record.message) ?? record.raw : record.raw)
                        .font(.system(size: max(11, model.fontSize - 1), design: .monospaced)).lineSpacing(6)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(18)
                }.background(LumenStyle.inset(scheme).opacity(0.5))
                if record.isTruncated {
                    Label("消息过长，完整原文保存在会话文件中。", systemImage: "info.circle").font(.system(size: 10)).foregroundStyle(.orange).padding(14)
                }
                HStack {
                    Button { model.showContext() } label: { Label("查看上下文", systemImage: "text.alignleft") }.buttonStyle(.plain).font(.system(size: 11))
                    Spacer()
                    if model.selectedIDs.count > 1 { Text("已选择 \(model.selectedIDs.count) 条").font(.system(size: 10)).foregroundStyle(.secondary) }
                }.padding(18)
            } else {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "text.alignleft").font(.system(size: 27, weight: .ultraLight)).foregroundStyle(.tertiary)
                    Text("细节，值得看清。").font(.system(size: 16, weight: .medium)).tracking(-0.4)
                    Text("选择一条日志，查看完整消息、\nJSON 与关联上下文。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
                }.frame(maxWidth: .infinity)
                Spacer()
                Label("所有日志仅保存在本机", systemImage: "lock.shield").font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.bottom, 22)
            }
        }.frame(width: 300).background(LumenStyle.surface(scheme), in: RoundedRectangle(cornerRadius: 17))
            .clipShape(RoundedRectangle(cornerRadius: 17))
            .onChange(of: model.selectedRecord?.id) { _, _ in formatted = false }
    }
    private func property(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(name).foregroundStyle(.tertiary).frame(width: 36, alignment: .leading); Text(value).textSelection(.enabled).lineLimit(2); Spacer(minLength: 0) }.font(.system(size: 10))
    }
}
