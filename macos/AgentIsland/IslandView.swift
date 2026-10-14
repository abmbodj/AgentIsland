import AppKit
import QuartzCore
import SwiftUI

/// The island: one black object that is the notch, grows wings when sessions exist, and drops
/// down into a solid black panel when expanded (D32: always notch-black, one continuous object). Lives in a fixed transparent window; only the
/// visible shape receives the mouse (the controller toggles `ignoresMouseEvents`).
/// Panels are never key unless summoned, so SwiftUI controls must take the very first click.
final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class IslandView: NSView {
    // Layers / views, back to front.
    private let fill = CAShapeLayer()
    private let pill = CALayer()
    let hosting: FirstMouseHostingView<PanelView>

    // Collapsed glyphs.
    private var dots: [String: CALayer] = [:]
    private var styled: [String: String] = [:]
    private let overflow = CATextLayer()
    private let attentionDot = CALayer()
    private let attentionCount = CATextLayer()

    // Geometry.
    private(set) var notchWidth: CGFloat = 0
    private(set) var notchHeight: CGFloat = 32
    private(set) var hasNotch = true
    private let dot: CGFloat = 6, gap: CGFloat = 6, pad: CGFloat = 11, ear: CGFloat = 6, maxDots = 6
    static let panelWidth: CGFloat = 440

    /// Fixed coordinate space for all drawing ("envelope"); the window only covers `islandRect` of it.
    var envelope = CGSize(width: 620, height: 492)
    /// Visible island (incl. ears) in envelope coordinates. Empty when nothing is shown.
    private(set) var islandRect: CGRect = .zero
    var onHover: ((Bool) -> Void)?
    private(set) var expanded = false
    /// Called when the user clicks the island outside SwiftUI controls.
    var onClick: (() -> Void)?
    private let model: PanelModel

    init(model: PanelModel) {
        hosting = FirstMouseHostingView(rootView: PanelView(model: model))
        hosting.sizingOptions = []
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()


        let shapeView = NSView()
        shapeView.wantsLayer = true
        shapeView.layer = CALayer()
        shapeView.autoresizingMask = [.width, .height]
        fill.fillColor = Theme.notchBlack.cgColor
        shapeView.layer?.addSublayer(fill)
        shapeView.layer?.addSublayer(pill)
        addSubview(shapeView)
        self.shapeView = shapeView

        for t in [overflow, attentionCount] {
            t.contentsScale = 2
            t.fontSize = 11
            t.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            pill.addSublayer(t)
        }
        overflow.foregroundColor = Theme.secondary.cgColor
        attentionCount.foregroundColor = Theme.amber.cgColor
        attentionDot.backgroundColor = Theme.amber.cgColor
        attentionDot.cornerRadius = dot / 2
        pill.addSublayer(attentionDot)

        hosting.alphaValue = 0
        addSubview(hosting)
        hosting.frame = CGRect(x: 0, y: -2000, width: Self.panelWidth, height: 2000)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    private var shapeView: NSView!

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // When expanded only the notch band toggles; clicks that fall through the panel content don't.
        let p = convert(event.locationInWindow, from: nil)
        if !expanded || p.y >= envelope.height - notchHeight { onClick?() }
    }

    override func layout() {
        super.layout()
        shapeView.frame = CGRect(origin: .zero, size: envelope)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    func configure(notchWidth: CGFloat, notchHeight: CGFloat, hasNotch: Bool) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.hasNotch = hasNotch
    }

    // MARK: Rendering

    func render(snapshot: Snapshot, expanded: Bool, animated: Bool) {
        let visible = !snapshot.paused
        let sessions = visible ? snapshot.sessions : []
        let attention = visible ? snapshot.attention : 0
        let H = envelope.height, mid = envelope.width / 2
        let notchL = mid - notchWidth / 2, notchR = mid + notchWidth / 2
        let animate = animated && !Theme.reduceMotion
        let wasExpanded = self.expanded
        self.expanded = expanded && visible

        // Collapsed wings.
        let shown = Array(sessions.prefix(maxDots))
        let extra = sessions.count - shown.count
        var right: CGFloat = 0
        if !shown.isEmpty {
            right = pad * 2 + CGFloat(shown.count) * dot + CGFloat(shown.count - 1) * gap
            if extra > 0 { right += gap + 7 + Self.countWidth(extra) }
        }
        let left: CGFloat = attention > 0 ? pad * 2 + dot + 4 + Self.countWidth(attention) : 0
        let (cl, cr): (CGFloat, CGFloat) = hasNotch ? (notchL - left, notchR + right) : (mid - (left + right) / 2, mid + (left + right) / 2)

        // Target silhouette.
        let path: CGPath?
        if self.expanded {
            let w = Self.panelWidth
            let measured = model.contentHeight > 0 ? model.contentHeight : hosting.fittingSize.height
            let contentH = min(measured, H - notchHeight)
            let rect = CGRect(x: mid - w / 2, y: H - notchHeight - contentH, width: w, height: notchHeight + contentH)
            islandRect = rect.insetBy(dx: hasNotch ? -ear : 0, dy: 0)
            hosting.frame = CGRect(x: rect.minX, y: rect.minY - 2000 + contentH, width: w, height: 2000)
            path = islandPath(x0: rect.minX, x1: rect.maxX, bottom: rect.minY, radius: 20)
        } else if sessions.isEmpty {
            // Invisible: the hardware notch alone (still hoverable on notched displays).
            islandRect = hasNotch ? CGRect(x: notchL, y: H - notchHeight, width: notchWidth, height: notchHeight) : .zero
            path = nil
        } else {
            islandRect = CGRect(x: cl - (hasNotch ? ear : 0), y: H - notchHeight, width: cr - cl + (hasNotch ? 2 * ear : 0), height: notchHeight)
            path = islandPath(x0: cl, x1: cr, bottom: H - notchHeight, radius: min(10, notchHeight / 3))
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let from = fill.presentation()?.path ?? fill.path
        for l in [fill] {
            l.path = path
            if animate, let from, let path {
                let a = CASpringAnimation(keyPath: "path")
                a.fromValue = from
                a.toValue = path
                a.mass = 1
                a.stiffness = 300
                a.damping = 2 * sqrt(300) // critically damped: quick, no bounce
                a.duration = a.settlingDuration
                l.add(a, forKey: "path")
            }
        }
        layoutPill(shown: shown, extra: extra, attention: attention, leftEdge: cl, notchR: notchR, H: H)
        CATransaction.commit()

        // Cross-fades between the collapsed pill and the panel.
        if self.expanded != wasExpanded || !animated {
            let opening = self.expanded
            model.isOpen = opening
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = animate ? (opening ? 0.22 : 0.14) : 0
                ctx.allowsImplicitAnimation = true
                hosting.animator().alphaValue = opening ? 1 : 0
            })
            CATransaction.begin()
            CATransaction.setAnimationDuration(animate ? 0.16 : 0)
            pill.opacity = opening ? 0 : 1
            CATransaction.commit()
        }
        setAccessibilityLabel(Self.describe(sessions, attention: attention))
    }

    private func layoutPill(shown: [SessionInfo], extra: Int, attention: Int, leftEdge: CGFloat, notchR: CGFloat, H: CGFloat) {
        let y = H - notchHeight
        let ids = Set(shown.map(\.id))
        for (id, l) in dots where !ids.contains(id) {
            l.removeFromSuperlayer()
            dots[id] = nil
            styled[id] = nil
        }
        let left = attention > 0 ? pad * 2 + dot + 4 + Self.countWidth(attention) : 0
        var x = (hasNotch ? notchR : leftEdge + left) + pad
        for s in shown {
            let l = dots[s.id] ?? {
                let l = CALayer()
                pill.addSublayer(l)
                dots[s.id] = l
                return l
            }()
            let key = "\(s.agent)/\(s.state.rawValue)/\(Theme.reduceMotion)"
            if styled[s.id] != key {
                Glyph.style(l, agent: s.agent, state: s.state, size: dot)
                styled[s.id] = key
            }
            l.frame = CGRect(x: x, y: y + (notchHeight - dot) / 2, width: dot, height: dot)
            x += dot + gap
        }
        overflow.isHidden = extra <= 0
        overflow.string = "+\(extra)"
        overflow.frame = CGRect(x: x + 1, y: y + (notchHeight - 14) / 2, width: 40, height: 14)
        attentionDot.isHidden = attention == 0
        attentionCount.isHidden = attention == 0
        let ax = leftEdge + pad
        attentionDot.frame = CGRect(x: ax, y: y + (notchHeight - dot) / 2, width: dot, height: dot)
        attentionCount.string = "\(attention)"
        attentionCount.frame = CGRect(x: ax + dot + 4, y: y + (notchHeight - 14) / 2, width: 40, height: 14)
    }

    /// Square top flush with the screen edge, rounded bottom, concave ears into the menu bar
    /// on notched displays; a capsule in the menu bar strip elsewhere (collapsed only).
    private func islandPath(x0: CGFloat, x1: CGFloat, bottom y0: CGFloat, radius r: CGFloat) -> CGPath {
        let top = envelope.height
        let p = CGMutablePath()
        if hasNotch || expanded {
            let e = hasNotch ? ear : 0
            p.move(to: CGPoint(x: x0 - e, y: top))
            p.addQuadCurve(to: CGPoint(x: x0, y: top - e), control: CGPoint(x: x0, y: top))
            p.addLine(to: CGPoint(x: x0, y: y0 + r))
            p.addQuadCurve(to: CGPoint(x: x0 + r, y: y0), control: CGPoint(x: x0, y: y0))
            p.addLine(to: CGPoint(x: x1 - r, y: y0))
            p.addQuadCurve(to: CGPoint(x: x1, y: y0 + r), control: CGPoint(x: x1, y: y0))
            p.addLine(to: CGPoint(x: x1, y: top - e))
            p.addQuadCurve(to: CGPoint(x: x1 + e, y: top), control: CGPoint(x: x1, y: top))
            p.closeSubpath()
        } else {
            let inset: CGFloat = 3
            let rect = CGRect(x: x0, y: y0 + inset, width: x1 - x0, height: top - y0 - inset * 2)
            p.addRoundedRect(in: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2)
        }
        return p
    }

    private static func countWidth(_ n: Int) -> CGFloat {
        CGFloat(String(n).count) * 7 + 1
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
