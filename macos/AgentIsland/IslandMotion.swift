import AppKit
import QuartzCore

/// Scalar geometry keeps its velocity on reversal. Paths always contain the same segments,
/// including the degenerate top corners on a display without a notch.
struct IslandShape: Equatable {
    var values: [Double]
    init(left: CGFloat, right: CGFloat, bottom: CGFloat, radius: CGFloat, shoulder: CGFloat, top: CGFloat) {
        values = [left, right, bottom, radius, shoulder, top].map(Double.init)
    }
    init(values: [Double]) { self.values = values }

    /// Recover the rendered scalar geometry from our fixed path topology. CA interpolates
    /// between sampled paths, so its presentation position can differ from the analytic one.
    init?(path: CGPath, in envelope: CGSize) {
        let rendered = Self.elements(of: path)
        guard rendered.types == [.moveToPoint, .addQuadCurveToPoint, .addLineToPoint,
                                  .addQuadCurveToPoint, .addLineToPoint, .addQuadCurveToPoint,
                                  .addLineToPoint, .addQuadCurveToPoint, .closeSubpath],
              rendered.points.count == 12 else { return nil }
        let p = rendered.points
        let shape = IslandShape(left: p[1].x, right: p[10].x, bottom: p[4].y,
                                radius: p[5].x - p[1].x, shoulder: p[1].x - p[0].x, top: p[0].y)
        guard shape.values.allSatisfy({ $0.isFinite }) else { return nil }
        let recovered = Self.elements(of: shape.path(in: envelope))
        // Reject unsupported or malformed paths instead of approximating a visible shape.
        guard zip(rendered.points, recovered.points).allSatisfy({ a, b in
            a.x.isFinite && a.y.isFinite && abs(a.x - b.x) < 0.00001 && abs(a.y - b.y) < 0.00001
        }) else { return nil }
        self = shape
    }

    private static func elements(of path: CGPath) -> (types: [CGPathElementType], points: [CGPoint]) {
        var types: [CGPathElementType] = [], points: [CGPoint] = []
        path.applyWithBlock { element in
            let type = element.pointee.type
            types.append(type)
            let count: Int
            switch type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: count = 0
            @unknown default: count = 0
            }
            for i in 0..<count { points.append(element.pointee.points[i]) }
        }
        return (types, points)
    }

    func path(in envelope: CGSize) -> CGPath {
        let l = max(0, min(CGFloat(values[0]), envelope.width - 1))
        let r = max(l + 1, min(CGFloat(values[1]), envelope.width))
        let bottom = max(0, min(CGFloat(values[2]), envelope.height - 1))
        let top = max(bottom + 1, min(CGFloat(values[5]), envelope.height))
        let radius = max(0, min(CGFloat(values[3]), (r - l) / 2, (top - bottom) / 2))
        let shoulder = max(-min((top - bottom) / 2, (r - l) / 2), min(CGFloat(values[4]), l, envelope.width - r, (top - bottom) / 2))
        let p = CGMutablePath()
        p.move(to: CGPoint(x: l - shoulder, y: top))
        p.addQuadCurve(to: CGPoint(x: l, y: top - abs(shoulder)), control: CGPoint(x: l, y: top))
        p.addLine(to: CGPoint(x: l, y: bottom + radius))
        p.addQuadCurve(to: CGPoint(x: l + radius, y: bottom), control: CGPoint(x: l, y: bottom))
        p.addLine(to: CGPoint(x: r - radius, y: bottom))
        p.addQuadCurve(to: CGPoint(x: r, y: bottom + radius), control: CGPoint(x: r, y: bottom))
        p.addLine(to: CGPoint(x: r, y: top - abs(shoulder)))
        p.addQuadCurve(to: CGPoint(x: r + shoulder, y: top), control: CGPoint(x: r, y: top))
        p.closeSubpath()
        return p
    }
}

final class IslandTrajectory {
    // e^(-omega*t) leaves less than 0.01 point of a typical 600-point flight.
    static let omega = 24.0
    static let duration = 0.6
    private(set) var target: IslandShape
    private var start: [Double]
    private var velocity: [Double]
    private var began = 0.0
    private(set) var generation = 0
    private(set) var isAnimating = false

    init(initial: IslandShape) {
        target = initial
        start = initial.values
        velocity = initial.values.map { _ in 0 }
    }

    func sample(at time: Double) -> (position: [Double], velocity: [Double]) {
        guard isAnimating else { return (target.values, target.values.map { _ in 0 }) }
        let t = max(0, time - began), w = Self.omega, decay = exp(-w * t)
        var p = start, v = velocity
        for i in p.indices {
            let d = start[i] - target.values[i], c = velocity[i] + w * d
            p[i] = target.values[i] + (d + c * t) * decay
            v[i] = (velocity[i] - w * c * t) * decay
        }
        return (p, v)
    }

    @discardableResult
    func retarget(_ shape: IslandShape, at time: Double, animated: Bool, reconfigure: Bool = false,
                  visibleStart: IslandShape? = nil) -> Bool {
        guard reconfigure || shape != target || (!animated && isAnimating) else { return false }
        let current = sample(at: time)
        generation += 1
        start = visibleStart?.values ?? current.position
        velocity = current.velocity
        target = shape
        began = time
        isAnimating = animated
        return true
    }

    @discardableResult
    func complete(generation: Int) -> Bool {
        guard generation == self.generation, isAnimating else { return false }
        isAnimating = false
        return true
    }

    func keyframes(in envelope: CGSize) -> [CGPath] {
        // Bounded allocation only on changed targets; CA interpolates these outside our process.
        (0...72).map { n in
            if n == 72 { return target.path(in: envelope) }
            return IslandShape(values: sample(at: began + Double(n) / 72 * Self.duration).position).path(in: envelope)
        }
    }

    func sweptBounds(in envelope: CGSize) -> CGRect {
        guard isAnimating else { return target.path(in: envelope).boundingBoxOfPath }
        // The derivative has at most one zero per scalar. Include those extrema, then form
        // a conservative rectangle; this also covers the tiny final keyframe snap to target.
        var times = [0.0, Self.duration]
        for i in start.indices {
            let c = velocity[i] + Self.omega * (start[i] - target.values[i])
            if c != 0 {
                let t = velocity[i] / (Self.omega * c)
                if t > 0 && t < Self.duration { times.append(t) }
            }
        }
        let samples = times.map { sample(at: began + $0).position } + [target.values]
        let left = samples.map { $0[0] }.min()!, right = samples.map { $0[1] }.max()!
        let ear = max(0, samples.map { $0[4] }.max()!)
        let bottom = samples.map { $0[2] }.min()!, top = samples.map { $0[5] }.max()!
        return CGRect(x: left - ear, y: bottom, width: right - left + ear * 2, height: top - bottom)
            .intersection(CGRect(origin: .zero, size: envelope))
    }
}

/// Owns only silhouette/mask motion. Generation checks reject callbacks from replaced flights.
final class IslandMotion: NSObject, CAAnimationDelegate {
    private let fill: CAShapeLayer
    private let mask: CAShapeLayer
    private var trajectory: IslandTrajectory?
    private var envelope = CGSize.zero
    private(set) var bounds = CGRect.zero
    var isAnimating: Bool { trajectory?.isAnimating ?? false }
    var onCompletion: (() -> Void)?

    init(fill: CAShapeLayer, mask: CAShapeLayer) { self.fill = fill; self.mask = mask }

    /// Keep window layout monotonic while CA owns an active flight. Reversals can need a
    /// smaller swept region, but shrinking now forces AppKit/SwiftUI layout on every input.
    static func windowBounds(current: CGRect, required: CGRect, animating: Bool) -> CGRect {
        if animating && !current.isEmpty {
            return required.isEmpty ? current : current.union(required).integral
        }
        return required.isEmpty ? .zero : required.integral
    }

    func set(_ shape: IslandShape, in envelope: CGSize, animated: Bool) {
        let time = CACurrentMediaTime()
        let reconfigure = self.envelope != envelope
        self.envelope = envelope
        // Screen reconfiguration uses the new coordinate-space constraints immediately.
        // Keep the trajectory instance so generations remain monotonic across screen changes.
        let animate = animated && !reconfigure
        if trajectory == nil {
            trajectory = IslandTrajectory(initial: shape)
            fill.path = shape.path(in: envelope)
            mask.path = fill.path
            bounds = fill.path!.boundingBoxOfPath
            return
        }
        guard let trajectory,
              reconfigure || shape != trajectory.target || (!animate && trajectory.isAnimating) else { return }
        let visibleStart = animate && trajectory.isAnimating
            ? fill.presentation()?.path.flatMap { IslandShape(path: $0, in: envelope) } : nil
        trajectory.retarget(shape, at: time, animated: animate, reconfigure: reconfigure, visibleStart: visibleStart)
        let generation = trajectory.generation
        // Replace after invalidating the old generation: CA can call animationDidStop on removal.
        fill.removeAnimation(forKey: "island.path")
        mask.removeAnimation(forKey: "island.path")
        fill.path = shape.path(in: envelope)
        mask.path = fill.path
        bounds = trajectory.sweptBounds(in: envelope)
        guard animate else { return }
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = trajectory.keyframes(in: envelope)
        animation.beginTime = time
        animation.duration = IslandTrajectory.duration
        animation.calculationMode = .linear
        animation.setValue(generation, forKey: "generation")
        animation.delegate = self
        fill.add(animation, forKey: "island.path")
        animation.delegate = nil
        mask.add(animation, forKey: "island.path")
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag, let generation = anim.value(forKey: "generation") as? Int,
              let trajectory, trajectory.complete(generation: generation) else { return }
        bounds = fill.path?.boundingBoxOfPath ?? .zero
        onCompletion?()
    }
}
