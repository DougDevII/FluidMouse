import XCTest
import CoreGraphics
@testable import FluidMouseEvents

final class SyntheticEventFactoryTests: XCTestCase {
    func testClickUsesTypedEventsForLeftRightAndOther() throws {
        let factory = MouseButtonEventFactory { CGPoint(x: 55, y: 66) }
        let left = try XCTUnwrap(factory.makeEvent(button: 0, down: true, flags: []))
        XCTAssertEqual(left.type, .leftMouseDown)
        XCTAssertEqual(left.getIntegerValueField(.mouseEventButtonNumber), 0)
        let right = try XCTUnwrap(factory.makeEvent(button: 1, down: true, flags: []))
        XCTAssertEqual(right.type, .rightMouseDown)
        let middle = try XCTUnwrap(factory.makeEvent(button: 2, down: true, flags: []))
        XCTAssertEqual(middle.type, .otherMouseDown)
        XCTAssertEqual(middle.getIntegerValueField(.mouseEventButtonNumber), 2)
        let extra = try XCTUnwrap(factory.makeEvent(button: 5, down: true, flags: []))
        XCTAssertEqual(extra.type, .otherMouseDown)
        XCTAssertEqual(extra.getIntegerValueField(.mouseEventButtonNumber), 5)
        for event in [left, right, middle, extra] {
            XCTAssertEqual(event.location, CGPoint(x: 55, y: 66))
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData),
                            MouseButtonEventFactory.marker)
        }
    }

    func testUpAndDraggedTypesFollowTheButton() throws {
        let factory = MouseButtonEventFactory { CGPoint(x: 0, y: 0) }
        XCTAssertEqual(try XCTUnwrap(factory.makeEvent(button: 0, down: false, flags: [])).type,
                       .leftMouseUp)
        XCTAssertEqual(try XCTUnwrap(factory.makeEvent(button: 1, down: false, flags: [])).type,
                       .rightMouseUp)
        XCTAssertEqual(try XCTUnwrap(factory.makeEvent(button: 4, down: false, flags: [])).type,
                       .otherMouseUp)
        let dragLeft = try XCTUnwrap(factory.makeDraggedEvent(button: 0, flags: []))
        XCTAssertEqual(dragLeft.type, .leftMouseDragged)
        let dragMiddle = try XCTUnwrap(factory.makeDraggedEvent(button: 2, flags: []))
        XCTAssertEqual(dragMiddle.type, .otherMouseDragged)
        XCTAssertEqual(dragMiddle.getIntegerValueField(.mouseEventButtonNumber), 2)
    }

    func testKeyboardEventCarriesKeycodeFlagsAndMarker() throws {
        let factory = KeyboardEventFactory()
        let down = try XCTUnwrap(factory.makeEvent(keycode: 126, down: true,
                                                   flags: [.maskControl]))
        XCTAssertEqual(down.type, .keyDown)
        XCTAssertEqual(down.getIntegerValueField(.keyboardEventKeycode), 126)
        XCTAssertEqual(down.flags, [.maskControl])
        XCTAssertEqual(down.getIntegerValueField(.eventSourceUserData),
                        ScrollEventFactory.marker)
        let up = try XCTUnwrap(factory.makeEvent(keycode: 126, down: false, flags: []))
        XCTAssertEqual(up.type, .keyUp)
        XCTAssertEqual(up.getIntegerValueField(.keyboardEventKeycode), 126)
    }

    func testFlagsChangedEventMarksModifierCaptureAndRelease() throws {
        let factory = KeyboardEventFactory()
        let down = try XCTUnwrap(factory.makeFlagsChangedEvent(keycode: 55, down: true, flags: [.maskCommand]))
        XCTAssertEqual(down.type, .flagsChanged)
        XCTAssertEqual(down.getIntegerValueField(.keyboardEventKeycode), 55)
        XCTAssertEqual(down.flags, [.maskCommand])
        XCTAssertEqual(down.getIntegerValueField(.eventSourceUserData), ScrollEventFactory.marker)
        let up = try XCTUnwrap(factory.makeFlagsChangedEvent(keycode: 55, down: false, flags: []))
        XCTAssertEqual(up.type, .flagsChanged)
        XCTAssertEqual(up.flags, CGEventFlags())
    }

    func testModifierSetMapsToCGFlags() {
        XCTAssertEqual(KeyboardEventFactory.flags([]), CGEventFlags())
        XCTAssertEqual(KeyboardEventFactory.flags([.shift]), [.maskShift])
        XCTAssertEqual(KeyboardEventFactory.flags([.control, .option, .command]),
                       [.maskControl, .maskAlternate, .maskCommand])
        XCTAssertEqual(KeyboardEventFactory.flags([.shift, .command, .option, .control]),
                       [.maskShift, .maskAlternate, .maskControl, .maskCommand])
    }
}
