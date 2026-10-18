import AppKit
import SwiftUI

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

    /// Claude Code's own Ultracode violet #d0b4ff, oklch(0.81 0.11 300): only on the Ultracode model chip.
    static let ultracode = NSColor(srgbRed: 0.816, green: 0.706, blue: 1.0, alpha: 1)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Restrained, shared timings. Native shell code can use the durations directly.
enum Motion {
    static let feedbackDuration = 0.12
    static let detailDuration = 0.22
    static let navigationDuration = 0.25
    static let reducedDuration = 0.1

    static func feedback(reduceMotion: Bool) -> Animation {
        .easeOut(duration: reduceMotion ? reducedDuration : feedbackDuration)
    }
    static func detail(reduceMotion: Bool) -> Animation? {
        // Disclosures change layout; a short ease still moves surrounding content.
        reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: detailDuration)
    }
    static func navigation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: feedbackDuration) : .timingCurve(0.22, 1, 0.36, 1, duration: navigationDuration)
    }
    static var screen: Animation { navigation(reduceMotion: Theme.reduceMotion) }
    static var quick: Animation? { detail(reduceMotion: Theme.reduceMotion) }
}

/// Countdown presentation derives from the response's original deadline, including after a remount.
/// This never schedules the response itself; PanelModel owns that deadline.
struct CountdownTiming {
    let remaining: TimeInterval
    let fraction: Double

    init(started: Date, duration: TimeInterval, now: Date) {
        let window = max(0, duration)
        remaining = max(0, min(window, window - now.timeIntervalSince(started)))
        fraction = window > 0 ? remaining / window : 0
    }
}

/// AppKit coordinates point upward. Build the clockwise arc explicitly so its origin stays at noon.
enum CountdownRingGeometry {
    static func path(in bounds: CGRect, lineWidth: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY),
                    radius: max(0, (min(bounds.width, bounds.height) - lineWidth) / 2),
                    startAngle: .pi / 2, endAngle: -3 * .pi / 2, clockwise: true)
        return path
    }
}

private struct Shift: ViewModifier {
    var dx: CGFloat
    var opacity: Double
    func body(content: Content) -> some View { content.offset(x: dx).opacity(opacity) }
}

extension AnyTransition {
    /// A screen pushed in from the trailing side (forward) or leading side (back); the old one drifts away the other way.
    static func screen(forward: Bool, reduceMotion: Bool = Theme.reduceMotion) -> AnyTransition {
        if reduceMotion { return .opacity }
        let d: CGFloat = 28
        return .asymmetric(
            insertion: .modifier(active: Shift(dx: forward ? d : -d, opacity: 0), identity: Shift(dx: 0, opacity: 1)),
            removal: .modifier(active: Shift(dx: forward ? -d : d, opacity: 0), identity: Shift(dx: 0, opacity: 1))
        )
    }

    /// A message or banner settling into the column.
    static func rise(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6))
    }
}

/// A disclosure can alter surrounding layout, so Reduced Motion uses its final state immediately.
/// This also suppresses inherited animation transactions when the preference changes mid-disclosure.
private struct StaticReducedDetail: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .transaction { transaction in
                if reduceMotion {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
            .animation(nil, value: reduceMotion)
    }
}

extension View {
    func staticDetailWhenReduced() -> some View { modifier(StaticReducedDetail()) }
}
