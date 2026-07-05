import AppKit
import SwiftUI

public enum L5Color {
    public static let background = Color(
        light: NSColor(calibratedRed: 0.980, green: 0.980, blue: 0.988, alpha: 1),
        dark: NSColor(calibratedRed: 0.075, green: 0.078, blue: 0.086, alpha: 1)
    )

    public static let secondaryBackground = Color(
        light: NSColor(calibratedRed: 0.957, green: 0.957, blue: 0.973, alpha: 1),
        dark: NSColor(calibratedRed: 0.108, green: 0.112, blue: 0.124, alpha: 1)
    )

    public static let surface = Color(
        light: NSColor(calibratedWhite: 1, alpha: 0.72),
        dark: NSColor(calibratedWhite: 1, alpha: 0.08)
    )

    public static let elevatedSurface = Color(
        light: NSColor(calibratedWhite: 1, alpha: 0.86),
        dark: NSColor(calibratedWhite: 1, alpha: 0.12)
    )

    public static let textPrimary = Color(
        light: NSColor(calibratedRed: 0.090, green: 0.090, blue: 0.090, alpha: 1),
        dark: NSColor(calibratedWhite: 0.94, alpha: 1)
    )

    public static let textSecondary = Color(
        light: NSColor(calibratedRed: 0.420, green: 0.447, blue: 0.502, alpha: 1),
        dark: NSColor(calibratedWhite: 0.70, alpha: 1)
    )

    public static let textMuted = Color(
        light: NSColor(calibratedRed: 0.612, green: 0.639, blue: 0.686, alpha: 1),
        dark: NSColor(calibratedWhite: 0.52, alpha: 1)
    )

    public static let border = Color(
        light: NSColor(calibratedWhite: 0, alpha: 0.08),
        dark: NSColor(calibratedWhite: 1, alpha: 0.10)
    )

    public static let accent = Color(
        light: NSColor(calibratedRed: 0.310, green: 0.427, blue: 1.000, alpha: 1),
        dark: NSColor(calibratedRed: 0.435, green: 0.553, blue: 1.000, alpha: 1)
    )

    public static let selectedSurface = Color(
        light: NSColor(calibratedRed: 0.310, green: 0.427, blue: 1.000, alpha: 0.10),
        dark: NSColor(calibratedRed: 0.435, green: 0.553, blue: 1.000, alpha: 0.18)
    )

    public static let success = Color(
        light: NSColor(calibratedRed: 0.086, green: 0.639, blue: 0.290, alpha: 1),
        dark: NSColor(calibratedRed: 0.247, green: 0.820, blue: 0.463, alpha: 1)
    )

    public static let warning = Color(
        light: NSColor(calibratedRed: 0.961, green: 0.620, blue: 0.043, alpha: 1),
        dark: NSColor(calibratedRed: 0.984, green: 0.737, blue: 0.020, alpha: 1)
    )

    public static let danger = Color(
        light: NSColor(calibratedRed: 0.863, green: 0.149, blue: 0.149, alpha: 1),
        dark: NSColor(calibratedRed: 0.973, green: 0.444, blue: 0.444, alpha: 1)
    )
}

private extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let bestMatch = appearance.bestMatch(from: [.darkAqua, .aqua])
            return bestMatch == .darkAqua ? dark : light
        })
    }
}
