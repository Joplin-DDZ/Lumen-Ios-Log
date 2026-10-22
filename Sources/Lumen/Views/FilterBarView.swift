import SwiftUI

/// 可组合筛选与独立搜索分开，收藏的规则可跨会话复用。
struct FilterBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var showSave = false
    @State private var filterName = ""

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                field("包含关键词，用 , ， | 表示或", symbol: "plus.magnifyingglass", text: $model.filter.include)
                    .help("普通模式下用英文逗号、中文逗号或 | 分隔，命中任一关键词即显示")
                field("排除关键词，用 , ， | 表示或", symbol: "minus.magnifyingglass", text: $model.filter.exclude)
                    .help("用英文逗号、中文逗号或 | 分隔，命中任一关键词即隐藏；排除始终按普通文本匹配")
                Toggle("正则", isOn: $model.filter.regex).font(.system(size: 11)).toggleStyle(.checkbox).help("正则仅作用于包含条件")
                IconButton(symbol: "bookmark", label: "收藏当前筛选") { showSave = true }
                    .disabled(!model.filter.hasConditions || model.filter.validationError != nil)
                IconButton(symbol: "arrow.counterclockwise", label: "重置筛选") { model.resetFilters() }
            }
            HStack(spacing: 7) {
                Text("级别").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.trailing, 3)
                ForEach(LogLevel.allCases, id: \.self) { level in
                    let selected = model.filter.levels.contains(level)
                    Button {
                        if selected { model.filter.levels.remove(level) } else { model.filter.levels.insert(level) }
                    } label: {
                        Text(level.title).font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(selected ? LumenStyle.level(level) : .secondary)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(selected ? LumenStyle.level(level).opacity(0.13) : LumenStyle.inset(scheme), in: Capsule())
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if let error = model.filter.validationError { Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(1) }
                else { Text("未选择级别时显示全部").font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
        }.padding(.horizontal, 18).padding(.vertical, 15)
            .background(LumenStyle.surface(scheme), in: RoundedRectangle(cornerRadius: 15))
            .sheet(isPresented: $showSave) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("收藏这个筛选").font(.system(size: 21, weight: .semibold))
                    TextField("例如：蓝牙连接异常", text: $filterName).textFieldStyle(.roundedBorder).frame(width: 300)
                    HStack { Spacer(); Button("取消") { showSave = false }; Button("收藏") { model.saveFilter(name: filterName); filterName = ""; showSave = false }.buttonStyle(.borderedProminent).disabled(filterName.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction) }
                }.padding(28)
            }
    }
    private func field(_ placeholder: String, symbol: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.tertiary)
            TextField(placeholder, text: text).textFieldStyle(.plain)
        }.font(.system(size: 11)).padding(.horizontal, 11).padding(.vertical, 9)
            .background(LumenStyle.inset(scheme), in: RoundedRectangle(cornerRadius: 8))
    }
}
