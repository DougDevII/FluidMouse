import XCTest
import FluidMouseCore
@testable import FluidMouse

/// The polling rate shown for the active link comes from the typed link only.
/// Receiver and cable rates are deliberately different (4000 vs 1000 Hz), so a
/// wrong pick cannot pass by accident. Unknown/unread is never treated as cable.
final class RapooPollingReadoutTests: XCTestCase {
    func testReceiverLinkShowsTheReceiverRate() {
        XCTAssertEqual(RapooPollingReadout.activeHz(link: .receiver, receiverHz: 4000, wiredHz: 1000), 4000)
    }

    func testCableLinkShowsTheCableRate() {
        XCTAssertEqual(RapooPollingReadout.activeHz(link: .cable, receiverHz: 4000, wiredHz: 1000), 1000)
    }

    func testUnknownLinkShowsNoRateEvenWhenBothAreKnown() {
        XCTAssertNil(RapooPollingReadout.activeHz(link: .unknown, receiverHz: 4000, wiredHz: 1000))
    }

    func testNeverReportedLinkShowsNoRateEvenWhenBothAreKnown() {
        XCTAssertNil(RapooPollingReadout.activeHz(link: nil, receiverHz: 4000, wiredHz: 1000))
    }

    func testMissingRateForTheActiveLinkStaysMissing() {
        XCTAssertNil(RapooPollingReadout.activeHz(link: .cable, receiverHz: 4000, wiredHz: nil))
        XCTAssertNil(RapooPollingReadout.activeHz(link: .receiver, receiverHz: nil, wiredHz: 1000))
    }

    /// Unknown and unread have no description; cable and receiver do.
    func testDescriptionIsNilOnlyWhenTheLinkIsUnknown() {
        XCTAssertNil(RapooHidService.describe(.unknown))
        XCTAssertEqual(RapooHidService.describe(.cable), "Cabo USB")
        XCTAssertEqual(RapooHidService.describe(.receiver), "Receptor 2.4 GHz")
    }

    func testUnrecognizedLinkCodeIsUnknownNotCable() {
        XCTAssertEqual(RapooProtocol.link(from: 0xFF), .unknown)
        XCTAssertEqual(RapooProtocol.link(from: 0x41), .cable)
        XCTAssertEqual(RapooProtocol.link(from: 0x42), .receiver)
    }
}
