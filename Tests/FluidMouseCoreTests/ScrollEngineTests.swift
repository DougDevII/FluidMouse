import XCTest
@testable import FluidMouseCore

final class ScrollEngineTests: XCTestCase {
    private func drain(_ engine: inout ScrollEngine, fps: Double = 120) -> (x: Int, y: Int, frames: Int) {
        var x = 0, y = 0, frames = 0
        while engine.isAnimating && frames < 1_000 {
            let step = engine.step(elapsed: 1 / fps, timeConstant: 0.08)
            x += Int(step.x); y += Int(step.y); frames += 1
        }
        return (x, y, frames)
    }

    func testDistanceIsConservedAndSpreadAcrossFrames() {
        var engine = ScrollEngine(); engine.add(x: -37, y: 140)
        let result = drain(&engine)
        XCTAssertEqual(result.x, -37); XCTAssertEqual(result.y, 140)
        XCTAssertGreaterThan(result.frames, 20); XCTAssertFalse(engine.isAnimating)
    }

    func testIndependentOfFrameRate() {
        for fps in [60.0, 90, 120] {
            var engine = ScrollEngine(); engine.add(x: 18.3, y: -155.7)
            let result = drain(&engine, fps: fps)
            XCTAssertEqual(result.x, 18); XCTAssertEqual(result.y, -156)
        }
    }

    func testDirectionReversalCancelsPreviousTail() {
        var engine = ScrollEngine(); engine.add(x: 0, y: 300)
        _ = engine.step(elapsed: 0.01, timeConstant: 0.08)
        engine.add(x: 0, y: -70)
        XCTAssertEqual(drain(&engine).y, -70)
    }

    func testRapidWheelBurstsMergeWithoutLosingDistance() {
        var engine = ScrollEngine(); var total = 0
        for _ in 0..<20 {
            engine.add(x: 0, y: 45)
            total += Int(engine.step(elapsed: 0.015, timeConstant: 0.08).y)
        }
        total += drain(&engine).y
        XCTAssertEqual(total, 900)
    }

    func testCancelStopsAllPendingFrames() {
        var engine = ScrollEngine(); engine.add(x: 40, y: 600); engine.cancel()
        XCTAssertFalse(engine.isAnimating)
        let step = engine.step(elapsed: 0.016, timeConstant: 0.08)
        XCTAssertEqual(step.x, 0); XCTAssertEqual(step.y, 0)
    }

    func testLargeBacklogIsBounded() {
        var engine = ScrollEngine(); engine.add(x: 0, y: 1_000_000)
        XCTAssertEqual(drain(&engine).y, 1_800)
    }

    func testInvalidNumbersDoNotAnimateOrCrash() {
        var engine = ScrollEngine(); engine.add(x: .nan, y: .infinity)
        XCTAssertFalse(engine.isAnimating)
        engine.add(x: 0, y: 40)
        XCTAssertEqual(engine.step(elapsed: .nan, timeConstant: 0.08).y, 0)
        XCTAssertEqual(drain(&engine).y, 40)
    }

    func testFractionalPixelIsAccumulated() {
        var engine = ScrollEngine()
        for _ in 0..<10 { engine.add(x: 0, y: 0.1) }
        XCTAssertEqual(drain(&engine).y, 1)
    }

    func testTrackpadMomentumModifiedAndOwnEventsArePreserved() {
        func smooth(continuous: Bool = false, phase: Int64 = 0, momentum: Int64 = 0,
                    modified: Bool = false, own: Bool = false, enabled: Bool = true) -> Bool {
            ScrollPolicy.shouldSmooth(enabled: enabled, continuous: continuous, phase: phase,
                momentum: momentum, modified: modified, ownEvent: own)
        }
        XCTAssertTrue(smooth())
        XCTAssertFalse(smooth(continuous: true)); XCTAssertFalse(smooth(phase: 1))
        XCTAssertFalse(smooth(momentum: 1)); XCTAssertFalse(smooth(modified: true))
        XCTAssertFalse(smooth(own: true)); XCTAssertFalse(smooth(enabled: false))
    }

    func testSystemPixelDeltaIsPreferredWithoutChangingDirection() {
        XCTAssertEqual(ScrollPolicy.pixelDistance(points: -24, lines: -3), -24)
        XCTAssertEqual(ScrollPolicy.pixelDistance(points: 0, lines: 3), 36)
        XCTAssertEqual(ScrollPolicy.pixelDistance(points: 9_000, lines: 1), 600)
        XCTAssertEqual(ScrollPolicy.pixelDistance(points: .nan, lines: .nan), 0)
    }
}
