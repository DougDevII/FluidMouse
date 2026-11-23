import XCTest
import Combine
import FluidMouseCore
@testable import FluidMouse

/// Tests of the DPI draft model (pure) and of the real `AppController` write
/// flow with no device attached: nothing reaches HID, the write is completed as
/// `deviceMissing` through the production tracker/`onSettled` path (cell UI-04).
final class RapooDpiDraftTests: XCTestCase {
    private let valid = [800, 1600, 2400, 3200, 4000, 4800, 5200]

    private func draft(_ stages: [Int], enabled: Int = 2) -> RapooDpiDraft {
        RapooDpiDraft(stages: stages, enabledStages: enabled)
    }

    func testConfirmedTableIsConvertedWithTheCurrentScale() {
        let raw = RapooProtocol.DpiTable(stages: [8, 16, 24, 32, 40, 48, 52], enabledStages: 3)
        XCTAssertEqual(RapooDpiDraft.confirmed(raw, scale: 50), draft([400, 800, 1200, 1600, 2000, 2400, 2600], enabled: 3))
        XCTAssertEqual(RapooDpiDraft.confirmed(raw, scale: 1)?.stages, [8, 16, 24, 32, 40, 48, 52])
        XCTAssertNil(RapooDpiDraft.confirmed(nil, scale: 50))
    }

    func testDirtyOnlyWhenDraftDiffersFromConfirmedValues() {
        let confirmed = draft(valid)
        XCTAssertFalse(RapooDpiDraft.isDirty(draft: nil, confirmed: confirmed))
        XCTAssertFalse(RapooDpiDraft.isDirty(draft: confirmed, confirmed: confirmed))
        var edited = confirmed
        edited.setStage(0, to: 900)
        XCTAssertTrue(RapooDpiDraft.isDirty(draft: edited, confirmed: confirmed))
    }

    /// A refresh (new confirmed reading) must not replace an unconfirmed edit.
    func testRefreshKeepsDirtyDraftVisible() {
        let edited = draft([900] + valid.dropFirst())
        let refreshed = draft(valid, enabled: 3)
        XCTAssertEqual(RapooDpiDraft.displayed(draft: edited, confirmed: refreshed), edited)
        XCTAssertTrue(RapooDpiDraft.isDirty(draft: edited, confirmed: refreshed))
    }

    func testSuccessSettlesOnlyTheSubmittedDraft() {
        let submitted = draft(valid)
        XCTAssertNil(RapooDpiDraft.afterSuccess(current: submitted, submitted: submitted))

        var newerEdit = submitted
        newerEdit.setStage(0, to: 900)
        XCTAssertEqual(RapooDpiDraft.afterSuccess(current: newerEdit, submitted: submitted), newerEdit)
    }

    func testValidationRequiresExactlySevenStages() {
        XCTAssertNil(draft(valid).problem(scale: 1))
        XCTAssertNotNil(draft([]).problem(scale: 1))
        XCTAssertNotNil(draft(Array(valid.prefix(6))).problem(scale: 1))
        XCTAssertNotNil(draft(valid + [1000]).problem(scale: 1))
    }

    func testValidationAcceptsTheRangeAndStepOfTheScale() {
        XCTAssertNil(draft([1000, 1600, 2400, 3200, 4000, 4800, 26_000]).problem(scale: 50))
        XCTAssertNil(draft([100, 200, 300, 400, 500, 600, 26_000], enabled: 7).problem(scale: 1))
        XCTAssertNil(draft([100, 200, 300, 400, 500, 600, 26_000], enabled: 2).problem(scale: 1))
    }

    func testValidationRejectsOutOfRangeOffStepAndEnabledCounts() {
        XCTAssertNotNil(draft([1010, 1600, 2400, 3200, 4000, 4800, 5200]).problem(scale: 50))
        XCTAssertNotNil(draft([50, 1600, 2400, 3200, 4000, 4800, 5200]).problem(scale: 50))
        XCTAssertNotNil(draft([1000, 1600, 2400, 3200, 4000, 4800, 26_050]).problem(scale: 50))
        XCTAssertNotNil(draft([26_001, 1600, 2400, 3200, 4000, 4800, 5200]).problem(scale: 1))
        XCTAssertNotNil(draft(valid, enabled: 1).problem(scale: 50))
        XCTAssertNotNil(draft(valid, enabled: 8).problem(scale: 50))
    }

    /// Out-of-range input is kept and flagged, never truncated or clamped.
    func testEditKeepsOutOfRangeValueAndFlagsIt() {
        var edited = draft(valid)
        edited.setStage(0, to: 1010)
        XCTAssertEqual(edited.stages[0], 1010)
        XCTAssertNotNil(edited.problem(scale: 50))
    }

    func testEditOutsideTheStageListIsIgnored() {
        var edited = draft(valid)
        edited.setStage(9, to: 500)
        XCTAssertEqual(edited.stages, valid)
    }

    // MARK: Real write flow (AppController, no device)

    private func waitForSettledOperation(_ controller: AppController, id: String) -> RapooOperationTracker.Outcome? {
        let settled = expectation(description: "\(id) settled")
        var subscription: AnyCancellable?
        subscription = controller.$rapooOperations.sink { operations in
            if let outcome = operations[id]?.outcome, outcome != .pending {
                settled.fulfill()
            }
        }
        wait(for: [settled], timeout: 5)
        subscription?.cancel()
        return controller.rapooOperations[id]?.outcome
    }

    /// The write reaches the production tracker and is completed as
    /// `deviceMissing`; the failure must keep the edited draft and show the error.
    func testDpiWriteWithoutDeviceFailsAndKeepsEditedDraft() {
        let controller = AppController()
        let edited = draft(valid)
        controller.rapooDpiDraft = edited

        controller.setRapooDpi(edited.stages, enabledStages: edited.enabledStages)

        XCTAssertEqual(waitForSettledOperation(controller, id: "rapoo.dpi"), .failure(.deviceMissing))
        XCTAssertEqual(controller.rapooDpiDraft, edited)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testDpiTableWithoutSevenStagesIsRefusedBeforeAnyWrite() {
        let controller = AppController()
        controller.setRapooDpi(Array(valid.prefix(2)), enabledStages: 2)
        XCTAssertNil(controller.rapooOperations["rapoo.dpi"])
        XCTAssertEqual(controller.errorMessage, "A tabela de DPI precisa ter exatamente 7 estágios.")

        controller.errorMessage = nil
        controller.setRapooDpi(valid + [1000], enabledStages: 2)
        XCTAssertNil(controller.rapooOperations["rapoo.dpi"])
        XCTAssertNotNil(controller.errorMessage)
    }
}
