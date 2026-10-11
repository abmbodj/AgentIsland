import AppKit
import QuartzCore

/// The collapsed island: the notch grows black "wings". Right wing = one glyph per top-level
/// session; left wing = amber count, only when something needs input.
/// Drawn with Core Animation so the breathing dots run in the render server (≈0% app CPU).
final class PillView: NSView {
    private let shape = CAShapeLayer()
    private var dots: [String: CALayer] = [:]
    /// Last applied glyph per session, so unchanged dots keep their running animation.
    private var styled: [String: String] = [:]
    private let overflow = CATextLayer()
    private let attentionDot = CALayer()
    private let attentionCount = CATextLayer()

    private var notchWidth: CGFloat = 0
    private var hasNotch = true

    private let dot: CGFloat = 6
    private let gap: CGFloat = 6
    private let pad: CGFloat = 11
    private let ear: CGFloat = 6
    private let maxDots = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        shape.fillColor = Theme.notchBlack.cgColor
        layer?.addSublayer(shape)
        for t in [overflow, attentionCount] {
            t.contentsScale = 2
            t.fontSize = 11
            t.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            t.alignmentMode = .left
            layer?.addSublayer(t)
        }
        overflow.foregroundColor = Theme.secondary.cgColor
        attentionCount.foregroundColor = Theme.amber.cgColor
        attentionDot.backgroundColor = Theme.amber.cgColor
        attentionDot.cornerRadius = dot / 2
        layer?.addSublayer(attentionDot)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(notchWidth: CGFloat, hasNotch: Bool) {
        self.notchWidth = notchWidth
        self.hasNotch = hasNotch
    }

    // MARK: Layout

    private func countWidth(_ n: Int) -> CGFloat {
        CGFloat(String(n).count) * 7 + 1
    }

    func update(sessions: [SessionInfo], attention: Int, animated: Bool) {
        let shown = Array(sessions.prefix(maxDots))
        let extra = sessions.count - shown.count
        let h = bounds.height
        let mid = bounds.midX
        let notchL = mid - notchWidth / 2, notchR = mid + notchWidth / 2

        // Wing widths.
        var right: CGFloat = 0
        if !shown.isEmpty {
            right = pad * 2 + CGFloat(shown.count) * dot + CGFloat(shown.count - 1) * gap
            if extra > 0 { right += gap + 7 + countWidth(extra) }
        }
        let left: CGFloat = attention > 0 ? pad * 2 + dot + 4 + countWidth(attention) : 0
        // Without a notch the pill is a capsule centred on the screen.
        let leftEdge: CGFloat, rightEdge: CGFloat
        if hasNotch {
            leftEdge = notchL - left
            rightEdge = notchR + right
        } else {
            let total = left + right
            leftEdge = mid - total / 2
            rightEdge = mid + total / 2
        }

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        let newPath = sessions.isEmpty ? nil : islandPath(from: leftEdge, to: rightEdge, height: h)
        if animated, let from = shape.presentation()?.path ?? shape.path, let to = newPath {
            let a = CASpringAnimation(keyPath: "path")
            a.fromValue = from
            a.toValue = to
            a.mass = 1
            a.stiffness = 320
            a.damping = 2 * sqrt(320) // critically damped: no bounce on routine updates
            a.duration = a.settlingDuration
            shape.add(a, forKey: "path")
        }
        shape.path = newPath

        // Session glyphs.
        let ids = Set(shown.map(\.id))
        for (id, l) in dots where !ids.contains(id) {
            l.removeFromSuperlayer()
            dots[id] = nil
            styled[id] = nil
        }
        var x = (hasNotch ? notchR : leftEdge + left) + pad
        for s in shown {
            let l = dots[s.id] ?? {
                let l = CALayer()
                layer?.addSublayer(l)
                dots[s.id] = l
                return l
            }()
            let key = "\(s.agent)/\(s.state.rawValue)/\(Theme.reduceMotion)"
            if styled[s.id] != key {
                style(l, for: s)
                styled[s.id] = key
            }
            l.frame = CGRect(x: x, y: (h - dot) / 2, width: dot, height: dot)
            x += dot + gap
        }
        overflow.isHidden = extra <= 0
        overflow.string = "+\(extra)"
        overflow.frame = CGRect(x: x + 1, y: (h - 14) / 2, width: 40, height: 14)

        // Attention wing.
        attentionDot.isHidden = attention == 0
        attentionCount.isHidden = attention == 0
        let ax = leftEdge + pad
        attentionDot.frame = CGRect(x: ax, y: (h - dot) / 2, width: dot, height: dot)
        attentionCount.string = "\(attention)"
        attentionCount.frame = CGRect(x: ax + dot + 4, y: (h - 14) / 2, width: 40, height: 14)
        CATransaction.commit()

        setAccessibilityLabel(Self.describe(sessions, attention: attention))
    }

    /// The black silhouette: square top flush with the screen edge, rounded bottom,
    /// concave "ears" that melt into the menu bar on notched displays.
    private func islandPath(from x0: CGFloat, to x1: CGFloat, height h: CGFloat) -> CGPath {
        let p = CGMutablePath()
        if hasNotch {
            let r = min(10, h / 3)
            p.move(to: CGPoint(x: x0 - ear, y: h))
            p.addQuadCurve(to: CGPoint(x: x0, y: h - ear), control: CGPoint(x: x0, y: h))
            p.addLine(to: CGPoint(x: x0, y: r))
            p.addQuadCurve(to: CGPoint(x: x0 + r, y: 0), control: CGPoint(x: x0, y: 0))
            p.addLine(to: CGPoint(x: x1 - r, y: 0))
            p.addQuadCurve(to: CGPoint(x: x1, y: r), control: CGPoint(x: x1, y: 0))
            p.addLine(to: CGPoint(x: x1, y: h - ear))
            p.addQuadCurve(to: CGPoint(x: x1 + ear, y: h), control: CGPoint(x: x1, y: h))
            p.closeSubpath()
        } else {
            let inset: CGFloat = 3
            let rect = CGRect(x: x0, y: inset, width: x1 - x0, height: h - inset * 2)
            p.addRoundedRect(in: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2)
        }
        return p
    }

    // MARK: Glyphs (shape = agent, color/motion = state; never color alone)

    private func style(_ l: CALayer, for s: SessionInfo) {
        l.sublayers?.forEach { $0.removeFromSuperlayer() }
        l.removeAnimation(forKey: "breathe")
        l.borderWidth = 0
        l.opacity = 1
        l.backgroundColor = nil
        l.cornerRadius = s.agent == "codex" ? 1.5 : dot / 2

        switch s.state {
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
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: 3.2))
            p.addLine(to: CGPoint(x: 2.3, y: 0.8))
            p.addLine(to: CGPoint(x: 6.5, y: 5.6))
            check.path = p
            check.strokeColor = Theme.green.cgColor
            check.fillColor = nil
            check.lineWidth = 1.6
            check.lineCap = .round
            check.lineJoin = .round
            check.frame = CGRect(x: -0.25, y: 0, width: dot, height: dot)
            l.addSublayer(check)
        case .stale:
            l.borderWidth = 1
            l.borderColor = Theme.muted.cgColor
        case .ended, .error:
            l.backgroundColor = Theme.muted.cgColor
            l.opacity = 0.6
        }
    }

    static func describe(_ sessions: [SessionInfo], attention: Int) -> String {
        if sessions.isEmpty { return "Agent Island: no agent sessions" }
        var parts = ["\(sessions.count) agent session\(sessions.count == 1 ? "" : "s")"]
        let working = sessions.filter { $0.state == .working }.count
        let finished = sessions.filter { $0.state == .finished }.count
        if working > 0 { parts.append("\(working) working") }
        if finished > 0 { parts.append("\(finished) finished") }
        if attention > 0 { parts.append("\(attention) need\(attention == 1 ? "s" : "") your input") }
        return parts.joined(separator: ", ")
    }
}
