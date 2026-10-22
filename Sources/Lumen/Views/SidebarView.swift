import SwiftUI

/// 左栏固定设备与会话入口，历史阅读不会停止正在进行的采集。
struct SidebarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appearanceMode") private var appearance = AppearanceMode.system.rawValue
    @State private var sessionToDelete: LogSession?
    private var accent: Color { LumenStyle.accent(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 37, height: 37).background(LumenStyle.blue, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lumen").font(.system(size: 23, weight: .semibold)).tracking(-0.8)
                    Text("iPHONE LOG STUDIO").font(.system(size: 8, weight: .medium)).tracking(1.5).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 24).padding(.top, 52).padding(.bottom, 30)

            Button { model.showLiveView() } label: {
                HStack(spacing: 11) {
                    Image(systemName: "waveform").font(.system(size: 14))
                    Text("App 控制台").font(.system(size: 13, weight: .medium))
                    Spacer()
                    if model.state.isActive { Circle().fill(.green).frame(width: 6, height: 6) }
                }.padding(.horizontal, 13).padding(.vertical, 12)
                    .foregroundStyle(model.selectedSessionID == nil || model.viewingLive ? accent : .primary)
                    .background(model.selectedSessionID == nil || model.viewingLive ? accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 11))
            }.buttonStyle(.plain).padding(.horizontal, 14)

            HStack {
                sectionTitle("设备")
                Spacer()
                Button { Task { await model.discover() } } label: {
                    if model.isDiscovering { ProgressView().controlSize(.mini).frame(width: 14, height: 14) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("刷新设备")
            }.padding(.horizontal, 26).padding(.top, 28).padding(.bottom, 10)
            if model.devices.isEmpty {
                Text("连接并信任你的 iPhone").font(.system(size: 11)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 26).padding(.vertical, 10)
            } else {
                ForEach(model.devices) { device in
                    Button {
                        model.selectedDeviceID = device.id; model.deviceChanged(); model.showLiveView()
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: "iphone").font(.system(size: 23, weight: .light))
                                .foregroundStyle(device.connected ? accent : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(device.connected ? "已连接 · iOS \(device.version)" : "未连接")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 2)
                            if device.id == model.selectedDeviceID { Circle().fill(device.connected ? Color.green : Color.secondary).frame(width: 5, height: 5) }
                        }.padding(.horizontal, 12).padding(.vertical, 11)
                            .background(device.id == model.selectedDeviceID ? LumenStyle.inset(scheme) : Color.clear, in: RoundedRectangle(cornerRadius: 11))
                    }.buttonStyle(.plain).padding(.horizontal, 14)
                }
            }

            HStack { sectionTitle("App 日志会话"); Spacer(); Text("\(model.sessions.count)").font(.system(size: 10)).foregroundStyle(.tertiary) }
                .help("自动保留最新 100 份会话；正在采集或导入的会话不会删除")
                .padding(.horizontal, 26).padding(.top, 28).padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if model.sessions.isEmpty {
                        Text("你的第一段记录，从这里开始。")
                            .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.vertical, 12)
                    }
                    ForEach(model.sessions) { session in
                        Button { model.selectSession(session.id) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: session.id == model.activeSessionID ? "record.circle" : "doc.text")
                                    .font(.system(size: 13, weight: .light)).foregroundStyle(session.id == model.activeSessionID ? accent : .secondary).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Spacer(minLength: 2)
                                        Text(session.count.formatted()).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                                    }
                                    Text(session.createdAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }.padding(12).contentShape(Rectangle())
                                .background(model.selectedSessionID == session.id ? LumenStyle.inset(scheme) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                            .contextMenu {
                                Button("在 Finder 中显示") { model.selectSession(session.id); model.revealSession() }
                                Divider()
                                Button("删除会话…", role: .destructive) { sessionToDelete = session }
                                    .disabled(!model.canDeleteSession(session.id))
                            }
                    }
                    if !model.savedFilters.isEmpty {
                        sectionTitle("收藏的筛选").padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 6)
                        ForEach(model.savedFilters) { saved in
                            Button { model.applyFilter(saved) } label: {
                                Label(saved.name, systemImage: "line.3.horizontal.decrease").font(.system(size: 12))
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                            }.buttonStyle(.plain).contextMenu { Button("移除收藏") { model.removeFilter(saved.id) } }
                        }
                    }
                }.padding(.horizontal, 14)
            }.scrollIndicators(.hidden)

            VStack(spacing: 17) {
                Button { model.importFile() } label: {
                    HStack { Image(systemName: "square.and.arrow.down"); Text(model.isImporting ? "正在导入…" : "导入日志文件"); Spacer(); Text("⌘O").font(.system(size: 10)) }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).disabled(model.isImporting)
                HStack {
                    Text("外观").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 2) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { appearance = mode.rawValue } } label: {
                                Image(systemName: mode.symbol).font(.system(size: 12)).frame(width: 29, height: 26)
                                    .foregroundStyle(appearance == mode.rawValue ? .primary : .secondary)
                                    .background(appearance == mode.rawValue ? LumenStyle.surface(scheme) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain).help(mode.title).accessibilityLabel(mode.title)
                        }
                    }.padding(3).background(LumenStyle.inset(scheme), in: RoundedRectangle(cornerRadius: 10))
                }
            }.padding(.horizontal, 26).padding(.top, 18).padding(.bottom, 24)
        }.frame(width: 248).background(LumenStyle.sidebar(scheme))
            .alert("删除日志会话？", isPresented: Binding(get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } }), presenting: sessionToDelete) { session in
                Button("取消", role: .cancel) { sessionToDelete = nil }
                Button("删除", role: .destructive) { Task { await model.deleteSession(session.id) }; sessionToDelete = nil }
            } message: { session in
                Text("将永久删除“\(session.title)”的全部日志和原始文件，无法撤销。")
            }
    }
    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
    }
}
