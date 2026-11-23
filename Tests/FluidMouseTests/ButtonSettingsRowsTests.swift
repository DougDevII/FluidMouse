import XCTest
import FluidMouseCore
@testable import FluidMouse

/// Pure helpers behind the button rows of UI-03: titles and the row list that
/// includes captured or mapped numbers beyond the standard nine.
final class ButtonSettingsRowsTests: XCTestCase {
    func testStandardNumbersKeepTheirTitles() {
        XCTAssertEqual(ButtonSettingsView.title(for: 0), "Esquerdo")
        XCTAssertEqual(ButtonSettingsView.title(for: 8), "Extra 6")
    }

    func testNumbersBeyondTheStandardListContinueTheExtraSequence() {
        XCTAssertEqual(ButtonSettingsView.title(for: 9), "Extra 7")
        XCTAssertEqual(ButtonSettingsView.title(for: 12), "Extra 10")
    }

    func testRowsAreStandardNumbersPlusMappedAndCapturedNumbers() {
        let rows = ButtonSettingsView.rowNumbers(
            mappings: [12: .disabled, 1: .scroll(.up)],
            captured: [9])
        XCTAssertEqual(rows, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 12])
    }

    func testRowsWithoutExtrasAreTheStandardList() {
        XCTAssertEqual(ButtonSettingsView.rowNumbers(mappings: [:], captured: []), Array(0...8))
    }
}
