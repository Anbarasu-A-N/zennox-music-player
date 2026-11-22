#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// DESIGN.md §2 tokens (OKLCH converted to sRGB). Everything else uses semantic system colours.
public enum ZennoxTheme {
    public static let accent = dynamic(light: (0.769, 0.428, 0.0), dark: (0.900, 0.632, 0.293))
    public static let lossless = dynamic(light: (0.167, 0.475, 0.360), dark: (0.444, 0.742, 0.615))
    public static let warning = dynamic(light: (0.810, 0.571, 0.0), dark: (0.894, 0.716, 0.314))
    public static let danger = dynamic(light: (0.801, 0.205, 0.175), dark: (0.919, 0.421, 0.370))
    public static let artworkPlaceholder = dynamic(light: (0.954, 0.938, 0.926), dark: (0.145, 0.128, 0.115))

    static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #elseif canImport(AppKit)
        return Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        return Color(red: light.0, green: light.1, blue: light.2)
        #endif
    }
}
#endif
