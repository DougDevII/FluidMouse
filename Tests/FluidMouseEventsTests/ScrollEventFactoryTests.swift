import XCTest
import CoreGraphics
@testable import FluidMouseEvents

final class ScrollEventFactoryTests: XCTestCase {
    func testEveryFrameUsesLiveCursorIncludingSmallMovements() throws {
        var cursor = CGPoint(x: 410, y: 220)
        let factory = ScrollEventFactory(cursorLocation: { cursor })
        for position in [CGPoint(x: 410, y: 220), CGPoint(x: 412, y: 221),
                         CGPoint(x: 411, y: 222), CGPoint(x: -150, y: 600)] {
            cursor = position
            let frame = try XCTUnwrap(factory.makeEvent(x: 0, y: -3, flags: []))
            XCTAssertEqual(frame.location, position)
            XCTAssertEqual(frame.type, .scrollWheel)
        }
    }

    func testSyntheticSourceDoesNotSuppressHardware() throws {
        let factory = ScrollEventFactory()
        let source = try XCTUnwrap(factory.source)
        XCTAssertEqual(source.localEventsSuppressionInterval, 0)
        let allowHardware: CGEventFilterMask = [.permitLocalMouseEvents,
            .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        for state in [CGEventSuppressionState.eventSuppressionStateSuppressionInterval,
                      .eventSuppressionStateRemoteMouseDrag] {
            XCTAssertEqual(source.getLocalEventsFilterDuringSuppressionState(state), allowHardware)
        }
    }

    func testFramesKeepScrollDistanceModifiersAndLoopProtection() throws {
        let factory = ScrollEventFactory(cursorLocation: { CGPoint(x: 100, y: 200) })
        let event = try XCTUnwrap(factory.makeEvent(x: 4, y: -7, flags: [.maskShift]))
        XCTAssertEqual(event.flags, [.maskShift])
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -7)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 4)
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), ScrollEventFactory.marker)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventScrollPhase), 0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventMomentumPhase), 0)
    }

    func testUnavailableCursorDoesNotEmitAnEventAtZero() {
        let unavailable = ScrollEventFactory(cursorLocation: { nil })
        XCTAssertNil(unavailable.makeEvent(x: 0, y: 3, flags: []))
        let invalid = ScrollEventFactory(cursorLocation: { CGPoint(x: Double.nan, y: 200) })
        XCTAssertNil(invalid.makeEvent(x: 0, y: 3, flags: []))
    }
}
