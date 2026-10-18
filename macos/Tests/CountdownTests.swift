// swiftc -parse-as-library macos/AgentIsland/Theme.swift macos/Tests/CountdownTests.swift -o /tmp/agent-island-countdown-tests && /tmp/agent-island-countdown-tests
import Foundation

@main
struct CountdownTests {
    static func main() {
        assert(Motion.detail(reduceMotion: true) == nil, "Reduced Motion detail changes must not interpolate layout")
        let started = Date(timeIntervalSinceReferenceDate: 1_000)
        let mountedLate = CountdownTiming(started: started, duration: 2, now: started.addingTimeInterval(0.75))
        assert(mountedLate.remaining == 1.25)
        assert(mountedLate.fraction == 0.625)
        // Rebuilding after an accessibility change must keep the original deadline.
        let resumed = CountdownTiming(started: started, duration: 2, now: started.addingTimeInterval(1.5))
        assert(resumed.remaining == 0.5)
        assert(resumed.fraction == 0.25)
        let expired = CountdownTiming(started: started, duration: 2, now: started.addingTimeInterval(3))
        assert(expired.remaining == 0 && expired.fraction == 0)
        let future = CountdownTiming(started: started, duration: 2, now: started.addingTimeInterval(-1))
        assert(future.remaining == 2 && future.fraction == 1)
        let zero = CountdownTiming(started: started, duration: 0, now: started)
        assert(zero.remaining == 0 && zero.fraction == 0)
        let negative = CountdownTiming(started: started, duration: -2, now: started)
        assert(negative.remaining == 0 && negative.fraction == 0)
        let bounds = CGRect(x: 0, y: 0, width: 11, height: 11)
        let path = CountdownRingGeometry.path(in: bounds, lineWidth: 1.6)
        var endpoints: [CGPoint] = []
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: endpoints.append(element.pointee.points[0])
            case .addQuadCurveToPoint: endpoints.append(element.pointee.points[1])
            case .addCurveToPoint: endpoints.append(element.pointee.points[2])
            case .closeSubpath: break
            @unknown default: fatalError("Unknown path element")
            }
        }
        let top = endpoints[0]
        assert(abs(top.x - bounds.midX) < 0.001)
        assert(abs(top.y - (bounds.maxY - 0.8)) < 0.001, "Countdown must start at twelve o'clock in unflipped AppKit coordinates")
        assert(endpoints[1].x > bounds.midX && endpoints[1].y < top.y, "Countdown must sweep clockwise from the top")
        let end = endpoints.last!
        assert(abs(end.x - top.x) < 0.001 && abs(end.y - top.y) < 0.001, "Full countdown must form a complete ring")
        print("Countdown deadline and geometry checks passed")
    }
}
