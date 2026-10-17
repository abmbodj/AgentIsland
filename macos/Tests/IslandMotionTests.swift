// Run: swiftc -parse-as-library macos/AgentIsland/IslandMotion.swift macos/Tests/IslandMotionTests.swift -o /tmp/agent-island-motion-tests && /tmp/agent-island-motion-tests
import AppKit
import QuartzCore

@main
struct IslandMotionTests {
    static func main() {
        let a = IslandShape(left: 220, right: 400, bottom: 460, radius: 10, shoulder: 6, top: 492)
        let b = IslandShape(left: 90, right: 530, bottom: 100, radius: 20, shoulder: 6, top: 492)
        let motion = IslandTrajectory(initial: a)
        assert(motion.retarget(b, at: 10, animated: true))
        let before = motion.sample(at: 10.11)
        assert(motion.retarget(a, at: 10.11, animated: true))
        let after = motion.sample(at: 10.11)
        for i in before.position.indices {
            assert(abs(before.position[i] - after.position[i]) < 0.000001, "Position must survive reversal")
            assert(abs(before.velocity[i] - after.velocity[i]) < 0.000001, "Velocity must survive reversal")
        }
        let generation = motion.generation
        assert(!motion.retarget(a, at: 10.12, animated: true), "Identical targets must not restart")
        assert(generation == motion.generation)
        assert(!motion.complete(generation: generation - 1))
        assert(motion.isAnimating)
        assert(motion.retarget(a, at: 10.13, animated: false), "Reduce Motion must cancel even an unchanged target")
        assert(!motion.isAnimating)
        assert(!motion.complete(generation: generation), "Cancelled completion must be stale")
        assert(motion.sample(at: 10.14).velocity.allSatisfy { $0 == 0 })
        let capsule = IslandShape(left: 220, right: 400, bottom: 463, radius: 13, shoulder: -13, top: 489)
        func topology(_ shape: IslandShape) -> [CGPathElementType] {
            var types: [CGPathElementType] = []
            shape.path(in: CGSize(width: 620, height: 492)).applyWithBlock { types.append($0.pointee.type) }
            return types
        }
        assert(topology(a) == topology(b) && topology(a) == topology(capsule))
        assert(motion.retarget(b, at: 20, animated: true))
        let bounds = motion.sweptBounds(in: CGSize(width: 620, height: 492))
        for n in 0...1000 {
            let shape = IslandShape(values: motion.sample(at: 20 + Double(n) / 1000 * IslandTrajectory.duration).position)
            assert(bounds.contains(shape.path(in: CGSize(width: 620, height: 492)).boundingBoxOfPath), "Window must cover the entire flight")
        }
        let rapid = IslandTrajectory(initial: a)
        let envelope = CGSize(width: 620, height: 492)
        var observedMomentumPastEndpoints = false
        for turn in 0..<24 {
            let time = 30 + Double(turn) * 0.075
            let target = turn.isMultiple(of: 2) ? b : a
            let start = rapid.sample(at: time)
            assert(rapid.retarget(target, at: time, animated: true))
            let resumed = rapid.sample(at: time)
            for i in start.position.indices {
                assert(abs(start.position[i] - resumed.position[i]) < 0.000001)
                assert(abs(start.velocity[i] - resumed.velocity[i]) < 0.000001)
            }
            let swept = rapid.sweptBounds(in: envelope)
            let endpoints = IslandShape(values: start.position).path(in: envelope).boundingBoxOfPath
                .union(target.path(in: envelope).boundingBoxOfPath)
            for n in 0...600 {
                let sample = rapid.sample(at: time + Double(n) / 600 * IslandTrajectory.duration)
                let pathBounds = IslandShape(values: sample.position).path(in: envelope).boundingBoxOfPath
                assert(swept.contains(pathBounds), "Rapid reversal bounds must cover momentum beyond both endpoints")
                if !endpoints.insetBy(dx: -0.001, dy: -0.001).contains(pathBounds) {
                    observedMomentumPastEndpoints = true
                }
            }
        }
        assert(observedMomentumPastEndpoints, "Fixture must exercise actual velocity overshoot, not only endpoint interpolation")
        let layer = CAShapeLayer(), mask = CAShapeLayer()
        let coordinator = IslandMotion(fill: layer, mask: mask)
        var completions = 0
        coordinator.onCompletion = { completions += 1 }
        coordinator.set(a, in: CGSize(width: 620, height: 492), animated: false)
        coordinator.set(b, in: CGSize(width: 620, height: 492), animated: true)
        assert(layer.animation(forKey: "island.path") is CAKeyframeAnimation)
        let staleAnimation = layer.animation(forKey: "island.path")!
        coordinator.set(a, in: CGSize(width: 620, height: 492), animated: true)
        coordinator.animationDidStop(staleAnimation, finished: true)
        assert(completions == 0 && coordinator.isAnimating, "Obsolete finished callbacks must not shrink the window")
        coordinator.animationDidStop(layer.animation(forKey: "island.path")!, finished: true)
        assert(completions == 1 && !coordinator.isAnimating, "Only current completion releases the envelope")
        coordinator.set(b, in: CGSize(width: 620, height: 492), animated: true)
        coordinator.set(b, in: CGSize(width: 620, height: 492), animated: false)
        assert(layer.animation(forKey: "island.path") == nil && mask.animation(forKey: "island.path") == nil)
        assert(completions == 1, "Cancellation must not finish an obsolete transition")
        let settledEnvelope = CGSize(width: 390, height: 400)
        coordinator.set(b, in: settledEnvelope, animated: false)
        assert(CGRect(origin: .zero, size: settledEnvelope).contains(layer.path!.boundingBoxOfPath),
               "Settled unchanged geometry must rebuild for a changed envelope")
        coordinator.set(b, in: envelope, animated: false)
        coordinator.set(a, in: envelope, animated: true)
        let beforeResize = layer.animation(forKey: "island.path")!
        let smallerEnvelope = CGSize(width: 390, height: 400)
        coordinator.set(a, in: smallerEnvelope, animated: false)
        assert(CGRect(origin: .zero, size: smallerEnvelope).contains(layer.path!.boundingBoxOfPath),
               "An unchanged target must still rebuild paths when the envelope changes")
        assert(layer.path!.boundingBoxOfPath == mask.path!.boundingBoxOfPath)
        assert(layer.animation(forKey: "island.path") == nil && !coordinator.isAnimating,
               "Envelope reconfiguration must cancel the previous coordinate-space flight")
        coordinator.animationDidStop(beforeResize, finished: true)
        assert(completions == 1, "Pre-resize completion must remain stale")
        coordinator.set(b, in: smallerEnvelope, animated: true)
        coordinator.animationDidStop(beforeResize, finished: true)
        assert(completions == 1 && coordinator.isAnimating, "Old envelope generations must not match new flights")
        assert((layer.animation(forKey: "island.path") as! CAKeyframeAnimation).values!.count <= 73,
               "A 600ms flight needs at most 73 samples for 120Hz interpolation")
        print("Island motion continuity, topology, bounds, unchanged target, envelope and cancellation checks passed")
    }
}
