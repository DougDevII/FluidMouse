import XCTest
@testable import FluidMouse

/// Debounce write coordinator (`RapooDebounceWrite`, used by
/// `RapooHidService.setDebounce`) and the `AppController` gate in front of it.
/// Doubles only: the timing block is a plain byte array (cell UI-04).
final class RapooDebounceWriteTests: XCTestCase {
    /// Press = 0x02, release = 0xFF ("no value" on this firmware), then sleep/flags.
    private let releaseUnset: [UInt8] = [0x02, 0xFF, 0x0A, 0x00]

    func testEditingPressKeepsReleaseByteExactlyIncludingFF() {
        let next = RapooDebounceWrite.merged(releaseUnset, pressIndex: 4, releaseIndex: nil)
        XCTAssertEqual(next, [0x04, 0xFF, 0x0A, 0x00])
        XCTAssertTrue(RapooDebounceWrite.matches(next, pressIndex: 4, releaseIndex: nil))
    }

    func testEditingReleaseKeepsPressByteExactly() {
        let next = RapooDebounceWrite.merged(releaseUnset, pressIndex: nil, releaseIndex: 5)
        XCTAssertEqual(next, [0x02, 0x05, 0x0A, 0x00])
        XCTAssertTrue(RapooDebounceWrite.matches(next, pressIndex: nil, releaseIndex: 5))
    }

    func testReadbackThatDiffersFromTheRequestedSideIsRejected() {
        XCTAssertFalse(RapooDebounceWrite.matches(releaseUnset, pressIndex: 4, releaseIndex: nil))
        XCTAssertFalse(RapooDebounceWrite.matches(releaseUnset, pressIndex: nil, releaseIndex: 5))
    }

    func testNegativeAndOutOfListIndicesAreRejectedWithoutTrap() {
        XCTAssertFalse(RapooDebounceWrite.isValid(pressIndex: -1, releaseIndex: nil))
        XCTAssertFalse(RapooDebounceWrite.isValid(pressIndex: nil, releaseIndex: -1))
        XCTAssertFalse(RapooDebounceWrite.isValid(pressIndex: 7, releaseIndex: nil))
        XCTAssertFalse(RapooDebounceWrite.isValid(pressIndex: nil, releaseIndex: 255))
        XCTAssertFalse(RapooDebounceWrite.isValid(pressIndex: nil, releaseIndex: nil))
        XCTAssertTrue(RapooDebounceWrite.isValid(pressIndex: 6, releaseIndex: nil))
        XCTAssertTrue(RapooDebounceWrite.isValid(pressIndex: nil, releaseIndex: 0))
    }

    func testShortBlockIsNotModifiedAndNeverVerified() {
        XCTAssertEqual(RapooDebounceWrite.merged([0x02], pressIndex: 3, releaseIndex: nil), [0x02])
        XCTAssertFalse(RapooDebounceWrite.matches([0x02], pressIndex: 3, releaseIndex: nil))
    }

    /// The AppController gate refuses invalid input before any write, so the
    /// negative index never reaches `UInt8(...)`.
    func testControllerRejectsInvalidDebounceBeforeAnyWrite() {
        let controller = AppController()
        controller.setRapooDebounce(pressIndex: -1, releaseIndex: nil)
        XCTAssertEqual(controller.errorMessage, "Escolha um tempo de debounce da lista.")
        XCTAssertNil(controller.rapooOperations["rapoo.debounce"])
    }

    /// No timing block has been read yet, so the write is refused.
    func testControllerRefusesDebounceWhenTimingWasNeverRead() {
        let controller = AppController()
        controller.setRapooDebounce(pressIndex: 2, releaseIndex: nil)
        XCTAssertEqual(controller.errorMessage, "Leia o mouse antes de alterar o debounce.")
        XCTAssertNil(controller.rapooOperations["rapoo.debounce"])
    }
}
