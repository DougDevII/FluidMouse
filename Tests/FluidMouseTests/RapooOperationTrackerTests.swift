import XCTest
@testable import FluidMouse

/// Pure state tests with doubles only — no HID device involved (cell UI-00).
final class RapooOperationTrackerTests: XCTestCase {
    let tracker = RapooOperationTracker()

    func testSuccessCallbackConcludesPendingOperation() {
        let token = tracker.begin("rapoo.dpi")
        XCTAssertTrue(tracker.finish("rapoo.dpi", token: token, atGeneration: 0, failure: nil))
        XCTAssertEqual(tracker.snapshots["rapoo.dpi"]?.outcome, .success)
    }

    func testFailureCallbackRecordsError() {
        let token = tracker.begin("rapoo.stage")
        XCTAssertTrue(tracker.finish("rapoo.stage", token: token, atGeneration: 0,
                                     failure: RapooHidService.RapooError.channelUnresponsive("0x880")))
        XCTAssertEqual(tracker.snapshots["rapoo.stage"]?.outcome,
                       .failure(.channelUnresponsive("0x880")))
    }

    /// `begin` replaces the pending operation for the same id — it does not
    /// block; the previous callback simply stops mattering when it arrives.
    func testBeginReplacesPendingOperationAndOldCallbackIsIgnored() {
        let oldToken = tracker.begin("rapoo.dpi")
        let newToken = tracker.begin("rapoo.dpi")
        XCTAssertNotEqual(oldToken, newToken)
        // The stale callback of the replaced operation must be ignored...
        XCTAssertFalse(tracker.finish("rapoo.dpi", token: oldToken, atGeneration: 0, failure: nil))
        XCTAssertEqual(tracker.snapshots["rapoo.dpi"]?.outcome, .pending)
        // ...and the new one lands normally.
        XCTAssertTrue(tracker.finish("rapoo.dpi", token: newToken, atGeneration: 0, failure: nil))
        XCTAssertEqual(tracker.snapshots["rapoo.dpi"]?.outcome, .success)
    }

    func testDisconnectInterruptsPendingAndRejectsOldGeneration() {
        tracker.begin("rapoo.dpi")
        tracker.begin("rapoo.stage")
        tracker.adoptConnectionGeneration(1)
        XCTAssertEqual(tracker.snapshots["rapoo.dpi"]?.outcome, .interrupted)
        XCTAssertEqual(tracker.snapshots["rapoo.stage"]?.outcome, .interrupted)
        // A callback from the dead connection arrives late: it is stale and must change nothing.
        XCTAssertFalse(tracker.finish("rapoo.dpi", token: tracker.snapshots["rapoo.dpi"]!.token,
                                      atGeneration: 0, failure: nil))
        XCTAssertEqual(tracker.snapshots["rapoo.dpi"]?.outcome, .interrupted)
    }

    func testFinishTwiceIsIgnored() {
        let token = tracker.begin("rapoo.sleep")
        XCTAssertTrue(tracker.finish("rapoo.sleep", token: token, atGeneration: 0, failure: nil))
        XCTAssertFalse(tracker.finish("rapoo.sleep", token: token, atGeneration: 0,
                                      failure: RapooHidService.RapooError.writeRejected("sleep")))
        XCTAssertEqual(tracker.snapshots["rapoo.sleep"]?.outcome, .success)
    }

    /// Deterministic walk of the **production delivery function**
    /// (`RapooOperationDelivery.deliver`, used by
    /// `RapooHidService.completeWrite`) for a callback that arrives late:
    /// disconnect → reconnect → new `begin`. The delivery must carry the
    /// generation captured at the IO queue (0), never the current one, and
    /// the tracker must then reject it.
    func testDelayedCallbackAfterDisconnectReconnectTraversesProductionDelivery() {
        let token = tracker.begin("rapoo.dpi") // accepted under generation 0
        // The IO queue already captured (nil, generation: 0). Meanwhile the
        // connection dies and reconnects.
        tracker.adoptConnectionGeneration(1)
        XCTAssertEqual(tracker.snapshots["rapoo.dpi"]?.outcome, .interrupted)

        // Production delivery hop with the immutable capture — the closure
        // only forwards what it was given. Assertions run inside the
        // callback (no mutable captured vars in @Sendable code).
        let deliveredExpectation = expectation(description: "delivery")
        RapooOperationDelivery.deliver(nil, generation: 0, to: { error, generation in
            XCTAssertEqual(error, nil)
            // Immutable capture: the label is the captured generation, not the
            // current one (1). This is the regression the review caught.
            XCTAssertEqual(generation, 0)
            deliveredExpectation.fulfill()
        })
        wait(for: [deliveredExpectation], timeout: 2)
        // The late callback carries the captured generation (0) and cannot
        // conclude the new connection's state.
        XCTAssertFalse(tracker.finish("rapoo.dpi", token: token,
                                      atGeneration: 0, failure: nil))
        XCTAssertEqual(tracker.snapshots["rapoo.dpi"]?.outcome, .interrupted)

        // The new connection's operation completes normally.
        let newToken = tracker.begin("rapoo.dpi")
        XCTAssertEqual(tracker.snapshots["rapoo.dpi"]?.generation, 1)
        XCTAssertTrue(tracker.finish("rapoo.dpi", token: newToken, atGeneration: 1, failure: nil))
        XCTAssertEqual(tracker.snapshots["rapoo.dpi"]?.outcome, .success)
    }

    /// The production coordinator itself: X is attempted; Y only when X
    /// landed and the firmware keeps a separate Y block; the first (X) error
    /// is authoritative and never replaced.
    ///
    /// These cases walk the **same function** `RapooHidService.setDpiTable`
    /// calls, with doubles standing in for the underlying block writes.
    func testDpiWriteCoordinator() {
        let xError = RapooHidService.RapooError.writeRejected("DPI X")
        let yError = RapooHidService.RapooError.writeRejected("DPI Y")

        // 1. X fails, scale > 1 → the X error comes out and Y is never called.
        do {
            var yCalled = false
            let error = RapooWritePlan.dpiWriteOutcome(scale: 50,
                writeX: { xError },
                writeY: { yCalled = true; return nil })
            XCTAssertEqual(error, xError)
            XCTAssertFalse(yCalled)
        }

        // 2. X fails, scale <= 1 → same contract: Y is not attempted either.
        do {
            var yCalled = false
            let error = RapooWritePlan.dpiWriteOutcome(scale: 1,
                writeX: { xError },
                writeY: { yCalled = true; return nil })
            XCTAssertEqual(error, xError)
            XCTAssertFalse(yCalled)
        }

        // 3. X succeeds, Y fails → the Y error is the one reported.
        do {
            var xCalled = false
            var yCalled = false
            let error = RapooWritePlan.dpiWriteOutcome(scale: 1,
                writeX: { xCalled = true; return nil },
                writeY: { yCalled = true; return yError })
            XCTAssertEqual(error, yError)
            XCTAssertTrue(xCalled); XCTAssertTrue(yCalled)
        }

        // 4. X succeeds, Y succeeds → no error.
        do {
            let error = RapooWritePlan.dpiWriteOutcome(scale: 1,
                writeX: { nil }, writeY: { nil })
            XCTAssertNil(error)
        }

        // 5. X succeeds, scale > 1 → success without touching Y (this is the
        //    branch that used to mask the X error with `error = nil`).
        do {
            var yCalled = false
            let error = RapooWritePlan.dpiWriteOutcome(scale: 50,
                writeX: { nil },
                writeY: { yCalled = true; return nil })
            XCTAssertNil(error)
            XCTAssertFalse(yCalled)
        }
    }
}
