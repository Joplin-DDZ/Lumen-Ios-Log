import SwiftUI

/// Apple 风格的中性色、系统字体与轻分隔；所有表面都适配深浅主题。
enum LumenStyle {
    static let blue = Color(red: 0.0, green: 0.44, blue: 0.89)
    static func canvas(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(white: 0.055) : Color(red: 0.962, green: 0.962, blue: 0.973) }
    static func sidebar(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(white: 0.085) : Color(red: 0.983, green: 0.983, blue: 0.988) }
    static func surface(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(red: 0.105, green: 0.105, blue: 0.12) : .white }
    static func inset(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.035) }
    static func hairline(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.055) }
    static func accent(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(red: 0.25, green: 0.65, blue: 1) : blue }
    static func level(_ level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .notice: return .teal
        case .warning: return .orange
        case .error: return .red
        case .fault: return .purple
        }
    }
}

/// 胶囊操作按钮使用轻微按压反馈，支持系统的减少动态效果设置。
struct PillButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .foregroundStyle(primary ? Color.white : Color.primary)
            .background(primary ? LumenStyle.blue : LumenStyle.inset(scheme), in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

struct IconButton: View {
    var symbol: String
    var label: String
    var active = false
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 30, height: 30)
                .foregroundStyle(active ? LumenStyle.accent(scheme) : .secondary)
                .background(active ? LumenStyle.accent(scheme).opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

struct LevelBadge: View {
    var level: LogLevel
    var body: some View {
        Text(level.title).font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(0.3).foregroundStyle(LumenStyle.level(level))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(LumenStyle.level(level).opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
    }
}
