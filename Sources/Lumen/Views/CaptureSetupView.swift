import SwiftUI

/// 唯一采集入口对应 Xcode 常用的 App 标准流；按钮明确说明会重启目标 App。
struct CaptureSetupView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("你的 App，它的控制台。").font(.system(size: 27, weight: .semibold)).tracking(-0.8)
                    Text("读取 print、业务日志和标准错误，保留中文与多行内容。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                IconButton(symbol: "xmark", label: "关闭") { dismiss() }
            }
            VStack(alignment: .leading, spacing: 12) {
                label("01", "选择设备")
                Picker("iPhone", selection: $model.selectedDeviceID) {
                    if model.devices.filter(\.connected).isEmpty { Text("未发现已连接的设备").tag("") }
                    ForEach(model.devices.filter(\.connected)) { device in Text("\(device.name) · iOS \(device.version)").tag(device.id) }
                }.labelsHidden().frame(maxWidth: .infinity).controlSize(.large)
                    .onChange(of: model.selectedDeviceID) { _, _ in model.deviceChanged() }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack { label("02", "选择 App"); Spacer(); if model.isLoadingTargets { ProgressView().controlSize(.mini) } }
                if !model.apps.isEmpty {
                    Picker("已安装的开发 App", selection: $model.bundleID) {
                        if !model.apps.contains(where: { $0.id == model.bundleID }) { Text("手动填写").tag(model.bundleID) }
                        ForEach(model.apps) { app in Text("\(app.name)  ·  \(app.id)").tag(app.id) }
                    }.controlSize(.large)
                        .onChange(of: model.bundleID) { _, value in if let app = model.apps.first(where: { $0.id == value }) { model.chooseApp(app) } }
                }
                HStack {
                    Text("Bundle ID").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    TextField("com.example.app", text: $model.bundleID).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                }.padding(12).background(LumenStyle.inset(scheme), in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 9) {
                Label("启动时接管 App 输出", systemImage: "terminal").font(.system(size: 13, weight: .medium))
                Text("将启动所选 App；若它已经运行，会先重启。原 Xcode 调试会话会结束。停止采集不会关闭 App。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(LumenStyle.accent(scheme).opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            HStack {
                Label("日志仅保存在这台 Mac", systemImage: "internaldrive").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(PillButtonStyle())
                Button("重启 App 并采集") {
                    Task { await model.startCapture() }; dismiss()
                }.buttonStyle(PillButtonStyle(primary: true)).disabled(!model.canStart)
            }.padding(.top, 4)
        }.padding(32).frame(width: 570).background(LumenStyle.surface(scheme))
    }
    private func label(_ number: String, _ title: String) -> some View {
        HStack(spacing: 9) { Text(number).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary); Text(title).font(.system(size: 12, weight: .semibold)) }
    }
}
