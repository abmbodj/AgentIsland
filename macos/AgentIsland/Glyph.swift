import AppKit
import QuartzCore
import SwiftUI

/// Session glyph: shape = agent (Claude circle, Codex rounded square), color + motion = state.
/// Core Animation only, so breathing runs in the render server rather than our process.
enum Glyph {
    static func style(_ l: CALayer, agent: String, state: SessionState, size: CGFloat) {
        l.sublayers?.forEach { $0.removeFromSuperlayer() }
        l.removeAnimation(forKey: "breathe")
        l.borderWidth = 0
        l.opacity = 1
        l.backgroundColor = nil
        l.cornerRadius = agent == "codex" ? size * 0.25 : size / 2

        switch state {
        case .working:
            if Theme.reduceMotion {
                l.borderWidth = 1.2
                l.borderColor = Theme.ink.cgColor
            } else {
                l.backgroundColor = Theme.ink.cgColor
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 1
                a.toValue = 0.35
                a.duration = 0.8
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                l.add(a, forKey: "breathe")
            }
        case .idle:
            l.backgroundColor = Theme.ink.cgColor
            l.opacity = 0.35
        case .needsInput:
            l.backgroundColor = Theme.amber.cgColor
        case .finished:
            let check = CAShapeLayer()
            let s = size / 6
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: 3.2 * s))
            p.addLine(to: CGPoint(x: 2.3 * s, y: 0.8 * s))
            p.addLine(to: CGPoint(x: 6.5 * s, y: 5.6 * s))
            check.path = p
            check.strokeColor = Theme.green.cgColor
            check.fillColor = nil
            check.lineWidth = max(1.6, size / 4)
            check.lineCap = .round
            check.lineJoin = .round
            check.frame = CGRect(x: -0.25 * s, y: 0, width: size, height: size)
            l.addSublayer(check)
        case .stale:
            l.borderWidth = 1
            l.borderColor = Theme.muted.cgColor
        case .ended, .error:
            l.backgroundColor = Theme.muted.cgColor
            l.opacity = 0.6
        }
    }
}

/// SwiftUI wrapper for row glyphs.
struct GlyphView: NSViewRepresentable {
    var agent: String
    var state: SessionState
    var size: CGFloat = 8

    final class V: NSView {
        var key = ""
    }

    func makeNSView(context: Context) -> V {
        let v = V()
        v.wantsLayer = true
        v.layer = CALayer()
        return v
    }

    func updateNSView(_ v: V, context: Context) {
        let key = "\(agent)/\(state.rawValue)/\(Theme.reduceMotion)"
        guard key != v.key, let l = v.layer else { return }
        v.key = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        Glyph.style(l, agent: agent, state: state, size: size)
        CATransaction.commit()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: V, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

/// Official Claude / Codex mark: Claude in its brand clay, Codex in off-white (its mark is monochrome).
struct AgentMark: View {
    var agent: String
    var size: CGFloat = 14

    var body: some View {
        Image(agent == "codex" ? "CodexMark" : "ClaudeMark")
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .foregroundStyle(Color(nsColor: agent == "codex" ? Theme.ink : Theme.claudeClay))
            .frame(width: size, height: size)
            .accessibilityLabel(Fmt.agentName(agent))
    }
}

/// Agent mark with the state glyph as a corner badge (avatar + presence).
struct AgentBadge: View {
    var agent: String
    var state: SessionState
    var size: CGFloat = 16

    var body: some View {
        AgentMark(agent: agent, size: size)
            .overlay(alignment: .bottomTrailing) {
                GlyphView(agent: agent, state: state, size: 7)
                    .frame(width: 7, height: 7)
                    .padding(2)
                    .background(Circle().fill(Color(nsColor: Theme.notchBlack)))
                    .offset(x: 4, y: 4)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Fmt.agentName(agent))
    }
}

/// Shared press feedback for panel buttons, plus a focus ring when keyboard navigation lands on one.
struct IslandButtonStyle: ButtonStyle {
    var radius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, radius: radius)
    }

    private struct Styled: View {
        let configuration: Configuration
        let radius: CGFloat
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !Theme.reduceMotion ? 0.97 : 1)
                .opacity(configuration.isPressed ? 0.8 : 1)
                .overlay(
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(Color(nsColor: Theme.ink).opacity(focused ? 0.5 : 0), lineWidth: 1.5)
                )
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}
