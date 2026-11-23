import XCTest
@testable import FluidMouse

/// Pure state tests for the operation indicators introduced by UI-01
/// (`PendingMarker` / `NotAppliedChip` logic) — snapshot-driven, no HID, no
/// view rendering (visual/VoiceOver verification stays manual and is reported
/// separately).
final class RapooOperationChipTests: XCTestCase {
    private func snapshot(_ outcome: RapooOperationTracker.Outcome) -> [String: RapooOperationTracker.Snapshot] {
        ["rapoo.dpi": RapooOperationTracker.Snapshot(outcome: outcome, generation: 0, token: 1)]
    }

    func testPendingMarkerOnlyShowsWhileCallbackHasNotArrived() {
        XCTAssertTrue(PendingMarker(operations: snapshot(.pending), id: "rapoo.dpi").pending)
        XCTAssertFalse(PendingMarker(operations: snapshot(.success), id: "rapoo.dpi").pending)
        XCTAssertFalse(PendingMarker(operations: snapshot(.interrupted), id: "rapoo.dpi").pending)
        XCTAssertFalse(PendingMarker(operations: snapshot(.failure(.deviceMissing)), id: "rapoo.dpi").pending)
        // A id the tracker never heard of shows nothing.
        XCTAssertFalse(PendingMarker(operations: [:], id: "rapoo.dpi").pending)
    }

    func testNotAppliedChipShowsOnlyForFailureOrInterruption() {
        XCTAssertTrue(NotAppliedChip(operations: snapshot(.failure(.deviceMissing)), id: "rapoo.dpi").failed)
        XCTAssertTrue(NotAppliedChip(operations: snapshot(.interrupted), id: "rapoo.dpi").failed)
        // Never over a success, a pending run, or an unknown id — the chip
        // never invents an outcome the tracker didn't report.
        XCTAssertFalse(NotAppliedChip(operations: snapshot(.success), id: "rapoo.dpi").failed)
        XCTAssertFalse(NotAppliedChip(operations: snapshot(.pending), id: "rapoo.dpi").failed)
        XCTAssertFalse(NotAppliedChip(operations: [:], id: "rapoo.dpi").failed)
    }
}
