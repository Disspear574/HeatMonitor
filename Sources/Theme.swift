import AppKit
import SwiftUI

extension Color {
    // Follows the window's light or dark appearance.
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

/// Colours and sizes from the approved window mockup.
enum Theme {
    static let edge: CGFloat = 16
    static let gap: CGFloat = 12
    static let cardRadius: CGFloat = 10
    static let barRadius: CGFloat = 3
    static let sidebarWidth: CGFloat = 212
    static let rowHeight: CGFloat = 28

    static let cardTop = Color(light: 0xffffff, dark: 0x303035)
    static let cardBottom = Color(light: 0xf5f5f7, dark: 0x29292d)
    static let cardHighlight = Color(light: 0xffffff, dark: 0xffffff, lightAlpha: 0.9, darkAlpha: 0.10)
    static let shadowNear = Color(light: 0x000000, dark: 0x000000, lightAlpha: 0.10, darkAlpha: 0.5)
    static let shadowFar = Color(light: 0x000000, dark: 0x000000, lightAlpha: 0.07, darkAlpha: 0.30)
    static let track = Color(light: 0x000000, dark: 0xffffff, lightAlpha: 0.09, darkAlpha: 0.12)
}

extension TempLevel {
    var word: String { NSLocalizedString(wordKey, tableName: "Status", comment: "") }

    // Darker shades in light mode keep text contrast on white.
    var text: Color {
        switch self {
        case .ok: Color(light: 0x1f8a3b, dark: 0x32d74b)
        case .warm: Color(light: 0x8a6100, dark: 0xffd60a)
        case .hot: Color(light: 0xc2410c, dark: 0xff9f0a)
        case .crit: Color(light: 0xd1242f, dark: 0xff6961)
        }
    }

    var fill: Color {
        switch self {
        case .ok: Color(light: 0x34c759, dark: 0x32d74b)
        case .warm: Color(light: 0xf0b400, dark: 0xffd60a)
        case .hot: Color(light: 0xff8a00, dark: 0xff9f0a)
        case .crit: Color(light: 0xff3b30, dark: 0xff453a)
        }
    }
}

/// Card with volume: one-tone gradient, a lit top edge and a two-layer shadow, no border.
private struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        content
            .padding(.vertical, 12).padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(LinearGradient(colors: [Theme.cardTop, Theme.cardBottom], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        shape.strokeBorder(LinearGradient(colors: [Theme.cardHighlight, .clear], startPoint: .top,
                                                          endPoint: UnitPoint(x: 0.5, y: 0.12)), lineWidth: 1)
                    }
                    .shadow(color: Theme.shadowNear, radius: 1, y: 1)
                    .shadow(color: Theme.shadowFar, radius: 8, y: 6)
            }
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}

/// Small caption above a card's content.
struct CardTitle: View {
    let key: LocalizedStringKey
    init(_ key: LocalizedStringKey) { self.key = key }
    var body: some View {
        Text(key).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }
}

/// Horizontal bar filled to `fraction` in `color`.
struct LevelBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Theme.barRadius).fill(Theme.track)
                RoundedRectangle(cornerRadius: Theme.barRadius).fill(color)
                    .frame(width: g.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
    }
}
