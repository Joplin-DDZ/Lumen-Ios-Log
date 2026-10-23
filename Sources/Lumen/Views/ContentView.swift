import SwiftUI

/// 主工作区保留阅读面积：简洁标题、独立搜索、可折叠筛选和详情栏。
struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var showSetup = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
            Rectangle().fill(LumenStyle.hairline(scheme)).frame(width: 1)
            VStack(alignment: .leading, spacing: 17) {
                header
                HStack(spacing: 12) { searchBar; actions }
                if model.showFilters { FilterBarView(model: model) }
                if let error = model.lastError { errorBanner(error) }
                HStack(alignment: .top, spacing: 16) {
                    logPanel
                    if model.showInspector { InspectorView(model: model) }
                }.frame(maxHeight: .infinity)
                footer
            }.padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 17)
                .background(LumenStyle.canvas(scheme))
        }.frame(minWidth: model.showInspector ? 1190 : 900, minHeight: 720)
            .tint(LumenStyle.accent(scheme))
            .sheet(isPresented: $showSetup) { CaptureSetupView(model: model) }
            .overlay(alignment: .bottom) {
                if let notice = model.notice {
                    Label(notice, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 19).padding(.vertical, 12).background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 42).transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: model.notice)
            .onReceive(NotificationCenter.default.publisher(for: .init("Lumen.NewCapture"))) { _ in if !model.state.isActive { showSetup = true } }
            .onReceive(NotificationCenter.default.publisher(for: .init("Lumen.FocusSearch"))) { _ in searchFocused = true }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Text(model.currentSession == nil || model.viewingLive ? "LIVE WORKSPACE" : "SESSION LIBRARY")
                        .font(.system(size: 9, weight: .medium)).tracking(1.7).foregroundStyle(.tertiary)
                    if model.viewingLive, model.state == .recording { Circle().fill(.green).frame(width: 4, height: 4) }
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(model.currentSession?.title ?? "App 控制台").font(.system(size: 29, weight: .semibold)).tracking(-1).lineLimit(1)
                    if let session = model.currentSession {
                        Text(session.sourceTitle).font(.system(size: 10)).foregroundStyle(.secondary)
                            .padding(.horizontal, 9).padding(.vertical, 5).background(LumenStyle.inset(scheme), in: Capsule())
                    }
                }
                Text(model.currentSession.map { "\($0.deviceName)  ·  \($0.createdAt.formatted(.dateTime.year().month().day().hour().minute()))" } ?? "只读取所选 App 的 print、业务日志与标准错误。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
            if model.isExporting { ProgressView().controlSize(.small) }
            Menu {
                Button("导出全部 · TXT") { model.export(json: false, all: true) }
                Button("导出全部 · JSONL") { model.export(json: true, all: true) }
                Divider()
                Button("导出当前筛选 · TXT") { model.export(json: false, all: false) }
                Button("导出当前筛选 · JSONL") { model.export(json: true, all: false) }
                Divider()
                Button("在 Finder 中显示原始文件") { model.revealSession() }
            } label: { Label("导出", systemImage: "square.and.arrow.up").font(.system(size: 11)).padding(.horizontal, 6) }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.selectedSessionID == nil || model.isExporting)
            if model.state.isActive {
                Button { model.stopCapture() } label: { Label("停止采集", systemImage: "stop.fill") }
                    .buttonStyle(PillButtonStyle()).disabled(model.state == .stopping)
            } else {
                Button { showSetup = true } label: { Label("开始采集", systemImage: "plus") }.buttonStyle(PillButtonStyle(primary: true))
            }
        }.padding(.bottom, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("在整个会话中搜索", text: $model.searchText).textFieldStyle(.plain).font(.system(size: 12))
                .focused($searchFocused).onSubmit { model.findNext(1) }.accessibilityLabel("搜索日志")
            if !model.searchText.isEmpty {
                Text(model.searchMatches.isEmpty ? "无匹配" : "\(max(0, model.searchIndex + 1)) / \(model.searchMatches.count)\(model.searchMatches.count == 100000 ? "+" : "")")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                IconButton(symbol: "chevron.up", label: "上一个结果") { model.findNext(-1) }.disabled(model.searchMatches.isEmpty)
                IconButton(symbol: "chevron.down", label: "下一个结果") { model.findNext(1) }.disabled(model.searchMatches.isEmpty)
                Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
            } else { Text("⌘F").font(.system(size: 10)).foregroundStyle(.tertiary) }
        }.padding(.horizontal, 14).frame(height: 40)
            .background(LumenStyle.surface(scheme), in: RoundedRectangle(cornerRadius: 12))
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(LogColumn.allCases) { column in
                    Toggle(column.title, isOn: Binding(
                        get: { !model.hiddenColumns.contains(column.rawValue) },
                        set: { model.setColumn(column, visible: $0) }
                    ))
                }
            } label: {
                Label("显示列", systemImage: "tablecells").font(.system(size: 12)).foregroundStyle(.secondary)
            }.menuStyle(.borderlessButton).fixedSize().help("勾选显示或隐藏每一列")
            IconButton(symbol: "line.3.horizontal.decrease", label: "筛选日志", active: model.showFilters || model.filter.hasConditions) { model.showFilters.toggle() }
            IconButton(symbol: model.autoScroll ? "pause" : "arrow.down.to.line", label: model.autoScroll ? "暂停自动滚动（继续采集）" : "滚动到最新日志", active: !model.autoScroll) {
                if model.autoScroll { model.autoScroll = false } else { model.resumeScrolling() }
            }
            Menu {
                Button("增大字号") { model.changeFontSize(1) }
                Button("减小字号") { model.changeFontSize(-1) }
                Divider()
                Text("当前 \(Int(model.fontSize)) pt")
            } label: { Image(systemName: "textformat.size").font(.system(size: 12)).foregroundStyle(.secondary) }.menuStyle(.borderlessButton).fixedSize().frame(width: 30)
            IconButton(symbol: "eraser", label: "清空视图，保留历史") { model.clearView() }.disabled(model.selectedSessionID == nil)
            IconButton(symbol: "sidebar.right", label: "显示或隐藏日志详情", active: model.showInspector) { model.showInspector.toggle() }
        }
    }

    private var logPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("日志流").font(.system(size: 12, weight: .semibold))
                Text(model.filteredCount.formatted()).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(LumenStyle.inset(scheme), in: Capsule())
                Spacer()
                if model.filter.hasConditions { Text("已筛选 / 共 \(model.totalCount.formatted()) 条").font(.system(size: 10)).foregroundStyle(.tertiary) }
                if model.filter.afterID > 0 { Button("恢复历史") { model.filter.afterID = 0 }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(LumenStyle.accent(scheme)) }
                if !model.autoScroll, model.viewingLive {
                    Button { model.resumeScrolling() } label: { Label("回到最新", systemImage: "arrow.down") }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(LumenStyle.accent(scheme))
                }
            }.padding(.horizontal, 17).frame(height: 49)
            Rectangle().fill(LumenStyle.hairline(scheme)).frame(height: 1)
            if model.rows.isEmpty { EmptyLogView(model: model) { showSetup = true } }
            else { LogTableView(model: model) }
            if model.filteredCount > model.pageSize {
                Rectangle().fill(LumenStyle.hairline(scheme)).frame(height: 1)
                HStack {
                    Button { model.movePage(-1) } label: { Label("较早", systemImage: "chevron.left") }.disabled(model.pageOffset == 0)
                    Spacer()
                    Text("\(model.pageOffset + 1) – \(min(model.filteredCount, model.pageOffset + model.rows.count)) / \(model.filteredCount.formatted())")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.movePage(1) } label: { HStack { Text("较新"); Image(systemName: "chevron.right") } }.disabled(model.pageOffset + model.rows.count >= model.filteredCount)
                }.font(.system(size: 10)).buttonStyle(.plain).padding(.horizontal, 18).padding(.vertical, 12)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LumenStyle.surface(scheme), in: RoundedRectangle(cornerRadius: 17))
            .clipShape(RoundedRectangle(cornerRadius: 17))
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(model.state == .recording ? Color.green : Color.secondary.opacity(0.4)).frame(width: 5, height: 5)
            Text(model.state.title).font(.system(size: 10))
            if model.state.isActive {
                Text("·").foregroundStyle(.tertiary)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("\(Date().timeIntervalSince(model.lastRecordAt) > 2 ? 0 : model.recordsPerSecond) 条 / 秒").font(.system(size: 10, design: .monospaced))
                }
            }
            Spacer()
            Label("自动保存 · 仅此 Mac", systemImage: "checkmark.shield").font(.system(size: 10))
            Text("Lumen 1.3").font(.system(size: 9, design: .monospaced)).padding(.leading, 15).foregroundStyle(.tertiary)
        }.foregroundStyle(.secondary).padding(.horizontal, 2)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(text).font(.system(size: 11)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            IconButton(symbol: "xmark", label: "关闭提示") { model.lastError = nil }
        }.padding(14).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}
