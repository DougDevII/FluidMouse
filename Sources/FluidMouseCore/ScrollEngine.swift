import Foundation

/// Animation state, independent of Quartz, timers, permissions and UI.
/// Each axis conserves rounded input distance, including fractional pixels.
public struct ScrollEngine {
    private struct Axis {
        var pending = 0.0
        var fraction = 0.0

        mutating func add(_ distance: Double) {
            if distance * (pending + fraction) < 0 { pending = 0; fraction = 0 }
            pending = min(1_800, max(-1_800, pending + distance))
        }

        mutating func advance(alpha: Double) -> Int32 {
            let movement: Double
            if abs(pending) < 0.1 { movement = pending; pending = 0 }
            else { movement = pending * alpha; pending -= movement }
            let exact = movement + fraction
            let pixels = exact.rounded(.toNearestOrAwayFromZero)
            fraction = exact - pixels
            return Int32(pixels)
        }
    }

    private var x = Axis()
    private var y = Axis()
    public var isAnimating: Bool { x.pending != 0 || y.pending != 0 }

    public init() {}

    public mutating func add(x dx: Double, y dy: Double) {
        guard dx.isFinite, dy.isFinite else { return }
        x.add(dx); y.add(dy)
    }

    public mutating func step(elapsed: Double, timeConstant: Double) -> (x: Int32, y: Int32) {
        guard elapsed.isFinite, elapsed > 0, timeConstant.isFinite, timeConstant > 0 else { return (0, 0) }
        let alpha = 1 - exp(-min(elapsed, 0.05) / timeConstant)
        return (x.advance(alpha: alpha), y.advance(alpha: alpha))
    }

    public mutating func cancel() { x = Axis(); y = Axis() }
}

public enum ScrollPolicy {
    /// Continuous input includes the native trackpad and mice whose drivers
    /// already provide smooth pixel events. Preserve those events byte-for-byte.
    public static func shouldSmooth(enabled: Bool, continuous: Bool, phase: Int64,
                                    momentum: Int64, modified: Bool, ownEvent: Bool) -> Bool {
        enabled && !continuous && phase == 0 && momentum == 0 && !modified && !ownEvent
    }

    public static func pixelDistance(points: Double, lines: Double) -> Double {
        // pointDelta carries the system's wheel acceleration; line fallback
        // supports drivers that omit it. Never reapply natural scrolling.
        if points.isFinite, points != 0 { return min(600, max(-600, points)) }
        guard lines.isFinite else { return 0 }
        return min(600, max(-600, lines * 12))
    }
}
