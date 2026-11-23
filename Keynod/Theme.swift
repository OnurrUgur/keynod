import SwiftUI

/// Linear-inspired palette. Every color follows the system's light or dark appearance.
enum Theme {
    static let nsBackground = NSColor.adaptive(light: NSColor(hex: 0xFBFBFC), dark: NSColor(hex: 0x0B0C0D))

    static let bg = Color(nsColor: nsBackground)
    static let elevated = Color(nsColor: .adaptive(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x17181A)))
    static let hover = Color(nsColor: .adaptive(light: NSColor.black.withAlphaComponent(0.04),
                                                dark: NSColor.white.withAlphaComponent(0.035)))
    static let selected = Color(nsColor: .adaptive(light: NSColor.black.withAlphaComponent(0.07),
                                                   dark: NSColor.white.withAlphaComponent(0.07)))
    static let border = Color(nsColor: .adaptive(light: NSColor.black.withAlphaComponent(0.09),
                                                 dark: NSColor.white.withAlphaComponent(0.08)))
    static let nsText = NSColor.adaptive(light: NSColor(hex: 0x1A1B1E), dark: NSColor(hex: 0xF7F8F8))
    static let nsAccent = NSColor(hex: 0x5E6AD2)
    static let text = Color(nsColor: nsText)
    static let textSecondary = Color(nsColor: .adaptive(light: NSColor(hex: 0x6B6F76), dark: NSColor(hex: 0x8A8F98)))
    static let textTertiary = Color(nsColor: .adaptive(light: NSColor(hex: 0x9A9EA6), dark: NSColor(hex: 0x5C6068)))
    static let accent = Color(hex: 0x5E6AD2)
    static let onAccent = Color.white
    static let yellow = Color(nsColor: .adaptive(light: NSColor(hex: 0xC99A06), dark: NSColor(hex: 0xF2C94C)))
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
