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
    private let contentClip = NSView()
    private let contentMask = CAShapeLayer()
    private lazy var motion = IslandMotion(fill: fill, mask: contentMask)
    /// Conservative active-flight bounds, used until the current CA animation actually finishes.
    var motionRect: CGRect {
        guard motion.isAnimating else { return islandRect }
        return islandRect.isEmpty ? motion.bounds : motion.bounds.union(islandRect)
    }
    var motionIsAnimating: Bool { motion.isAnimating }
    var onMotionCompletion: (() -> Void)? {
        didSet { motion.onCompletion = { [weak self] in self?.onMotionCompletion?() } }
    }

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
    /// List mode is 440 wide; an open chat widens to `PanelModel.chatWidth`.
    private var panelWidth: CGFloat { model.width }
    /// Room below the notch for the dropped-down panel (see `IslandController.reposition`).
    static let panelMaxHeight: CGFloat = 460
    /// Room below the notch when a chat is open.
    static let chatMaxHeight: CGFloat = PanelModel.chatHeight + 14

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

        contentClip.wantsLayer = true
        contentClip.layer?.mask = contentMask
        addSubview(contentClip)
        hosting.wantsLayer = true
        hosting.alphaValue = 0
        hosting.layer?.setValue(6, forKeyPath: "transform.translation.y")
        contentClip.addSubview(hosting)
        hosting.frame = CGRect(x: 0, y: -2000, width: PanelModel.listWidth, height: 2000)
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
        contentClip.frame = CGRect(origin: .zero, size: envelope)
        contentMask.frame = CGRect(origin: .zero, size: envelope)
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
        let shape: IslandShape
        let hidden = !self.expanded && sessions.isEmpty
        if self.expanded {
            let w = min(panelWidth, envelope.width - (hasNotch ? 2 * ear : 0))
            let measured = model.contentHeight > 0 ? model.contentHeight : hosting.fittingSize.height
            let contentH = max(0, min(measured, H - notchHeight))
            let rect = CGRect(x: mid - w / 2, y: H - notchHeight - contentH, width: w, height: notchHeight + contentH)
            islandRect = rect.insetBy(dx: hasNotch ? -ear : 0, dy: 0)
            hosting.frame = CGRect(x: rect.minX, y: rect.minY - 2000 + contentH, width: w, height: 2000)
            shape = islandShape(x0: rect.minX, x1: rect.maxX, bottom: rect.minY, radius: 20)
        } else if sessions.isEmpty {
            // Invisible: the hardware notch alone (still hoverable on notched displays).
            islandRect = hasNotch ? CGRect(x: notchL, y: H - notchHeight, width: notchWidth, height: notchHeight) : .zero
            // Notch-sized but hidden, so opening grows out of the notch instead of popping in.
            shape = islandShape(x0: hasNotch ? notchL : mid - 1, x1: hasNotch ? notchR : mid + 1, bottom: H - notchHeight, radius: min(10, notchHeight / 3))
        } else {
            islandRect = CGRect(x: cl - (hasNotch ? ear : 0), y: H - notchHeight, width: cr - cl + (hasNotch ? 2 * ear : 0), height: notchHeight)
            shape = islandShape(x0: cl, x1: cr, bottom: H - notchHeight, radius: min(10, notchHeight / 3))
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        motion.set(shape, in: envelope, animated: animate)
        fade(fill, to: hidden ? 0 : 1, duration: animate ? Motion.reducedDuration : (Theme.reduceMotion && animated ? Motion.reducedDuration : 0),
             delay: animate && hidden && motion.isAnimating ? IslandTrajectory.duration - Motion.reducedDuration : 0)
        layoutPill(shown: shown, extra: extra, attention: attention, leftEdge: cl, notchR: notchR, H: H)

        // Keep content clipped by the same moving silhouette on both opening and closing.
        // Reversals start at the presentation values, never at a hard-coded entrance offset.
        if self.expanded != wasExpanded || !animated {
            let opening = self.expanded
            model.isOpen = opening
            if let layer = hosting.layer {
                let opacity = layer.presentation()?.opacity ?? layer.opacity
                let translation = layer.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat
                    ?? layer.value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
                layer.removeAnimation(forKey: "island.content.opacity")
                layer.removeAnimation(forKey: "island.content.translation")
                hosting.alphaValue = opening ? 1 : 0
                layer.setValue(animate ? (opening ? 0 : 6) : 0, forKeyPath: "transform.translation.y")
                let duration = animate ? (opening ? Motion.detailDuration : Motion.feedbackDuration) : (Theme.reduceMotion && animated ? Motion.reducedDuration : 0)
                if duration > 0 {
                    let opacityAnimation = CABasicAnimation(keyPath: "opacity")
                    opacityAnimation.fromValue = opacity
                    opacityAnimation.toValue = opening ? 1 : 0
                    opacityAnimation.duration = duration
                    layer.add(opacityAnimation, forKey: "island.content.opacity")
                    if animate {
                        let translationAnimation = CABasicAnimation(keyPath: "transform.translation.y")
                        translationAnimation.fromValue = translation
                        translationAnimation.toValue = opening ? 0 : 6
                        translationAnimation.duration = duration
                        translationAnimation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                        layer.add(translationAnimation, forKey: "island.content.translation")
                    }
                }
            }
            fade(pill, to: opening ? 0 : 1, duration: animate ? Motion.feedbackDuration : (Theme.reduceMotion && animated ? Motion.reducedDuration : 0))
        }
        CATransaction.commit()
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

    private func islandShape(x0: CGFloat, x1: CGFloat, bottom: CGFloat, radius: CGFloat) -> IslandShape {
        let capsule = !hasNotch && !expanded
        let inset: CGFloat = capsule ? 3 : 0
        let r = capsule ? max(0, (notchHeight - 6) / 2) : radius
        return IslandShape(left: x0, right: x1, bottom: bottom + inset, radius: r,
                           shoulder: hasNotch ? ear : (capsule ? -r : 0), top: envelope.height - inset)
    }

    private func fade(_ layer: CALayer, to target: Float, duration: Double, delay: Double = 0) {
        let key = "island.opacity"
        guard duration == 0 || layer.opacity != target else { return }
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: key)
        layer.opacity = target
        guard duration > 0, from != target else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = target
        animation.beginTime = CACurrentMediaTime() + delay
        animation.duration = duration
        animation.fillMode = .backwards
        layer.add(animation, forKey: key)
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
