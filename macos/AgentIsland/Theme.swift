import AppKit

/// Design tokens (OKLCH-derived, see DESIGN.md). Color carries meaning only:
/// amber = needs you, green = finished. Everything routine is warm neutral.
enum Theme {
    /// Must match the physical notch exactly.
    static let notchBlack = NSColor.black
    /// oklch(0.94 0.008 85)
    static let ink = NSColor(srgbRed: 0.931, green: 0.921, blue: 0.899, alpha: 1)
    /// oklch(0.74 0.008 85)
    static let secondary = NSColor(srgbRed: 0.678, green: 0.668, blue: 0.648, alpha: 1)
    /// oklch(0.60 0.01 85)
    static let muted = NSColor(srgbRed: 0.513, green: 0.501, blue: 0.477, alpha: 1)
    /// oklch(0.82 0.16 75), reserved for "needs input"
    static let amber = NSColor(srgbRed: 1.0, green: 0.702, blue: 0.189, alpha: 1)
    /// oklch(0.80 0.17 150), reserved for "finished"
    static let green = NSColor(srgbRed: 0.368, green: 0.861, blue: 0.505, alpha: 1)

    /// Claude brand clay #D97757, oklch(0.67 0.13 39): only on the Claude mark, redder than amber.
    static let claudeClay = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
