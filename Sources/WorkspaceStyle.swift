import SwiftUI

enum WorkspaceStyle {
    static let canvas = Color(red: 0.071, green: 0.085, blue: 0.104)
    static let sidebar = Color(red: 0.091, green: 0.107, blue: 0.129)
    static let panel = Color(red: 0.108, green: 0.126, blue: 0.151)
    static let accent = Color(red: 0.55, green: 0.83, blue: 0.98)
    static let border = Color.white.opacity(0.10)
}

struct WorkspaceHeading: View {
    private let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    func workspacePanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        return padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceStyle.panel, in: shape)
            .overlay { shape.strokeBorder(WorkspaceStyle.border).allowsHitTesting(false) }
    }
}

struct WorkspaceButtonStyle: ButtonStyle {
    enum Role { case primary, secondary, stop, navigation, selected }

    let role: Role

    init(_ role: Role = .secondary) { self.role = role }

    func makeBody(configuration: Configuration) -> some View {
        ButtonSurface(configuration: configuration, role: role)
    }

    private struct ButtonSurface: View {
        let configuration: Configuration
        let role: Role
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        private var fill: Color {
            switch role {
            case .primary: WorkspaceStyle.accent
            case .stop: Color(red: 0.98, green: 0.73, blue: 0.71)
            case .selected: WorkspaceStyle.accent.opacity(0.15)
            case .secondary: Color.white.opacity(0.055)
            case .navigation: .clear
            }
        }

        private var ink: Color {
            switch role {
            case .primary, .stop: WorkspaceStyle.canvas
            case .selected: WorkspaceStyle.accent
            case .secondary, .navigation: .primary
            }
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 8)
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ink)
                .padding(.horizontal, 10)
                .frame(minHeight: 34)
                .background(fill, in: shape)
                .overlay {
                    shape.fill(ink.opacity(enabled ? configuration.isPressed ? 0.13 : hovering ? 0.08 : 0 : 0))
                        .allowsHitTesting(false)
                }
                .overlay {
                    if role == .secondary { shape.strokeBorder(WorkspaceStyle.border).allowsHitTesting(false) }
                }
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: hovering)
        }
    }
}
