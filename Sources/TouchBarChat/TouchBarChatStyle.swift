import AppKit
import SwiftUI

/// Quiet, system-adaptive surfaces inspired by the reading density of a notes
/// workspace. Accent is reserved for selection and the primary action.
enum TouchBarChatStyle {
    static let accent = adaptive("accent", light: 0x7044CC, dark: 0xB497FF)
    static let primaryAction = Color(red: 112 / 255, green: 68 / 255, blue: 204 / 255)
    static let canvas = adaptive("canvas", light: 0xFAFAFB, dark: 0x1C1C1F)
    static let sidebar = adaptive("sidebar", light: 0xF1F1F4, dark: 0x232328)
    static let recordList = adaptive("record-list", light: 0xFFFFFF, dark: 0x1F2024)
    static let surface = adaptive("surface", light: 0xFFFFFF, dark: 0x29292E)
    static let raisedSurface = adaptive("raised", light: 0xF7F7F9, dark: 0x303036)
    static let border = adaptive("border", light: 0xE6E6EA, dark: 0x3B3B43)
    static let accentWash = adaptive("accent-wash", light: 0xF0EAFC, dark: 0x352C49)
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)

    static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
        let color = NSColor(name: NSColor.Name("dev.touchbarchat.\(name)")) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
        return Color(nsColor: color)
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

struct TouchBarChatPanel: ViewModifier {
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(TouchBarChatStyle.surface, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(TouchBarChatStyle.border, lineWidth: 1)
            }
    }
}

struct TouchBarChatPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 34)
            .background(
                TouchBarChatStyle.primaryAction.opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

extension View {
    func touchBarChatPanel(cornerRadius: CGFloat = 14) -> some View {
        modifier(TouchBarChatPanel(cornerRadius: cornerRadius))
    }
}
