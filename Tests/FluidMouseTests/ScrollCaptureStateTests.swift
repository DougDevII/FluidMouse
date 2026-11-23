import XCTest
@testable import FluidMouse

/// Pure mapping from typed controller flags to the capture state shown by the
/// status menu and the test area (cell UI-05).
final class ScrollCaptureStateTests: XCTestCase {
    func testPausedWinsOverEverythingElse() {
        XCTAssertEqual(ScrollCaptureState.from(enabled: false, trusted: false, smoothyRunning: true, running: true), .paused)
    }

    func testMissingAccessibilityComesBeforeSmoothy() {
        XCTAssertEqual(ScrollCaptureState.from(enabled: true, trusted: false, smoothyRunning: true, running: false),
                       .needsAccessibility)
    }

    func testSmoothyBlocksActivation() {
        XCTAssertEqual(ScrollCaptureState.from(enabled: true, trusted: true, smoothyRunning: true, running: false),
                       .smoothyRunning)
    }

    func testRunningAndInactiveWhenEnabledTrustedAndClear() {
        XCTAssertEqual(ScrollCaptureState.from(enabled: true, trusted: true, smoothyRunning: false, running: true), .active)
        XCTAssertEqual(ScrollCaptureState.from(enabled: true, trusted: true, smoothyRunning: false, running: false), .inactive)
    }

    /// HIG for menu items: titles up to 30 characters.
    func testMenuTitlesFitTheThirtyCharacterLimit() {
        for state in ScrollCaptureState.allCases {
            XCTAssertLessThanOrEqual(state.title.count, 30, state.title)
        }
    }
}
