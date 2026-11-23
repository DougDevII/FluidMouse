import XCTest
@testable import FluidMouse

/// Pure validation tests for the exact speed field of the scroll tab (UI-02).
final class ScrollSpeedDraftTests: XCTestCase {
    func testAcceptsValuesInsideRangeWithDotOrComma() {
        XCTAssertEqual(ScrollSettingsView.parseSpeed("2.5"), 2.5)
        XCTAssertEqual(ScrollSettingsView.parseSpeed("2,5"), 2.5)
        XCTAssertEqual(ScrollSettingsView.parseSpeed(" 0.5 "), 0.5)
        XCTAssertEqual(ScrollSettingsView.parseSpeed("4"), 4)
    }

    func testRoundsToTheSliderStep() {
        XCTAssertEqual(ScrollSettingsView.parseSpeed("2.36"), 2.4)
    }

    func testRejectsOutOfRangeNonFiniteAndMalformedText() {
        for text in ["0.4", "4.1", "-1", "", "abc", "nan", "inf"] {
            XCTAssertNil(ScrollSettingsView.parseSpeed(text), text)
        }
    }

    func testCommitAppliesValidDraftRoundedToStep() {
        let committed = ScrollSettingsView.commitSpeed("2,36", current: 2)
        XCTAssertEqual(committed, 2.4)
        XCTAssertEqual(ScrollSettingsView.formatSpeed(committed), "2.4")
    }

    func testCommitKeepsCurrentValueWhenDraftIsInvalid() {
        XCTAssertEqual(ScrollSettingsView.commitSpeed("abc", current: 3), 3)
        XCTAssertEqual(ScrollSettingsView.commitSpeed("4.5", current: 1.5), 1.5)
        XCTAssertEqual(ScrollSettingsView.commitSpeed("", current: 0.5), 0.5)
    }

    func testFormatsWithOneDecimal() {
        XCTAssertEqual(ScrollSettingsView.formatSpeed(2), "2.0")
        XCTAssertEqual(ScrollSettingsView.formatSpeed(0.5), "0.5")
    }
}
