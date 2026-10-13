import SwiftUI
import AppKit

/// Design tokens from the "Media Downloader" design (light + dark).
enum Theme {
    private static func dyn(_ light: String, _ dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static let bg = dyn("#F4F5F7", "#0E1014")
    static let surface = dyn("#FFFFFF", "#15181E")
    static let surface2 = dyn("#F1F3F6", "#1C2028")
    static let elevated = dyn("#FFFFFF", "#1E222A")
    static let border = dyn("#E3E6EB", "#2A2F39")
    static let borderStrong = dyn("#CDD2DA", "#3A404C")
    static let text = dyn("#111318", "#ECEEF2")
    static let text2 = dyn("#4A5160", "#A6ADBA")
    static let text3 = dyn("#646B78", "#868E9C")
    static let accent = dyn("#3B82F6", "#3B82F6")
    static let accentText = dyn("#2563EB", "#6EA3F8")
    static let btn = dyn("#2563EB", "#2563EB")
    static let accentSoft = dyn("#3B82F617", "#3B82F61F")
    static let accentBorder = dyn("#3B82F661", "#3B82F666")
    static let track = dyn("#E4E7EC", "#272C36")
    static let skeleton = dyn("#E7EAEF", "#20242D")
    static let segActive = dyn("#FFFFFF", "#2E3440")
    static let success = dyn("#16A34A", "#22C55E")
    static let successText = dyn("#15803D", "#4ADE80")
    static let successSoft = dyn("#16A34A1C", "#22C55E24")
    static let danger = dyn("#DC2626", "#EF4444")
    static let dangerText = dyn("#B91C1C", "#F87171")
    static let dangerSoft = dyn("#DC26260F", "#EF44441A")
    static let dangerBorder = dyn("#DC262652", "#EF444466")
    static let warn = dyn("#D97706", "#F59E0B")
    static let warnText = dyn("#B45309", "#FBBF24")
    static let warnSoft = dyn("#D977061C", "#F59E0B24")
}

extension NSColor {
    /// "#RRGGBB" or "#RRGGBBAA"
    convenience init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        let hasAlpha = h.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

// MARK: - Button styles

struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 36
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16)
            .frame(height: height)
            .background(Theme.btn.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 36
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(isEnabled ? Theme.text : Theme.text3)
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(Theme.surface2.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(isEnabled ? Theme.borderStrong : Theme.border))
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.text3)
            .frame(width: 32, height: 32)
            .background(Theme.surface2.opacity(configuration.isPressed ? 1 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
}
