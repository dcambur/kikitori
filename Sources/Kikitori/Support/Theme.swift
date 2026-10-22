import AppKit
import SwiftUI

/// Design tokens from docs/design/spec.md §2.
extension Color {
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    init(hex: UInt32, alpha: Double = 1) { self.init(nsColor: NSColor(hex: hex, alpha: alpha)) }

    static let kkAccent = Color(light: 0x5E43CF, dark: 0xA894FF)
    static let kkAccentFill = Color(light: 0x6A4FD8, dark: 0x6E56E0)
    static let kkAccentSoft = Color(light: 0x6A4FD8, dark: 0xA894FF, lightAlpha: 0.12, darkAlpha: 0.16)
    static let kkSelection = Color(light: 0x6A4FD8, dark: 0xA894FF, lightAlpha: 0.14, darkAlpha: 0.20)
    static let kkNote = Color(light: 0x9A4B00, dark: 0xFFB547)
    static let kkNoteBackground = Color(light: 0xFF9F0A, dark: 0xFFB547, lightAlpha: 0.18, darkAlpha: 0.16)
    static let kkSuccess = Color(light: 0x1A7F37, dark: 0x4CD964)
    static let kkDanger = Color(light: 0xC4001A, dark: 0xFF6B61)
    static let kkInfo = Color(light: 0x0060C7, dark: 0x5AB0FF)
    static let kkInspector = Color(light: 0xF6F6F8, dark: 0x252528)
    static let kkSpeakers = [Color(light: 0x0B6E99, dark: 0x6CCBFF), Color(light: 0xB24A00, dark: 0xFFAE73),
                             Color(light: 0x2D7D1F, dark: 0x9FE07A), Color(light: 0xB0287A, dark: 0xF59AD4)]

    // Overlay (same in both appearances).
    static let overlayFill = Color(red: 16 / 255, green: 16 / 255, blue: 22 / 255)
    static let overlaySolid = Color(hex: 0x121216)
    static let overlayNote = Color(hex: 0xFFCB7A)
    static let overlayNoteBackground = Color(red: 1, green: 190 / 255, blue: 90 / 255).opacity(0.24)
    static let overlaySpeakers = [Color(hex: 0x7FD4FF), Color(hex: 0xFFB37A), Color(hex: 0xB9F27C), Color(hex: 0xF7A6DA)]

    /// Profile colours (spec §5.5).
    static let profileSwatches: [(name: String, hex: String)] = [
        ("Wisteria", "#8D7BE0"), ("Blue", "#2F8FB8"), ("Orange", "#C2571A"), ("Pink", "#C23A7A"), ("Green", "#3C8D5A"),
    ]

    init(hexString: String) {
        let v = UInt32(hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x8D7BE0
        self.init(hex: v)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Font {
    /// Japanese text: Hiragino Sans, never synthesised by SF Pro.
    static func japanese(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(weight == .regular ? "HiraginoSans-W3" : "HiraginoSans-W6", size: size)
    }
    static func overlay(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
}

extension View {
    /// Mark a Japanese text view for line breaking and VoiceOver.
    func japaneseText() -> some View {
        environment(\.locale, Locale(identifier: "ja"))
    }
}

enum Money {
    /// "$0.14", or "$0.004" below a cent (spec §6).
    static func format(_ value: Double) -> String {
        if value > 0 && value < 0.01 { return String(format: "$%.3f", value) }
        if value >= 1, value == value.rounded() { return String(format: "$%.0f", value) }
        return String(format: "$%.2f", value)
    }
}

enum TimeText {
    /// "1 h 13 min" / "13 min" / "45 s".
    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s >= 3600 { return "\(s / 3600) h \(s / 60 % 60) min" }
        if s >= 60 { return "\(s / 60) min" }
        return "\(s) s"
    }
}
