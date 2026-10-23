import XCTest
@testable import FluidMouseCore

final class ButtonMappingTests: XCTestCase {
    private func plan(_ mapping: ButtonAction?, button: Int, down: Bool) -> ButtonPlan {
        ButtonMappingResolver.plan(button: button, down: down, mapping: mapping)
    }

    func testUnmappedAndUnchangedButtonPassesThrough() {
        XCTAssertEqual(plan(nil, button: 3, down: true), .passThrough)
        XCTAssertEqual(plan(.unchanged, button: 3, down: true), .passThrough)
        XCTAssertEqual(plan(.unchanged, button: 3, down: false), .passThrough)
    }

    func testDisabledButtonIsSuppressedWhileDownAndUp() {
        XCTAssertEqual(plan(.disabled, button: 4, down: true), .suppress)
        XCTAssertEqual(plan(.disabled, button: 4, down: false), .suppress)
    }

    func testClickRemapConvertsDownAndUpPaired() {
        XCTAssertEqual(plan(.click(button: 2), button: 3, down: true), .clickDown(button: 2))
        XCTAssertEqual(plan(.click(button: 2), button: 3, down: false), .clickUp(button: 2))
    }

    func testSelfClickIsIgnored() {
        XCTAssertEqual(plan(.click(button: 2), button: 2, down: true), .passThrough)
        XCTAssertEqual(plan(.click(button: 2), button: 2, down: false), .passThrough)
    }

    func testActionsFireOnDownAndSuppressUp() {
        for action in [ButtonAction.scroll(.up), .key(KeyCombination(keycode: 36)),
                       .system(.missionControl)] {
            XCTAssertEqual(plan(action, button: 5, down: true), .execute(action))
            XCTAssertEqual(plan(action, button: 5, down: false), .suppress)
        }
    }

    func testDragsOnlyConvertForClickRemaps() {
        XCTAssertEqual(ButtonMappingResolver.planDrag(button: 3, mapping: .click(button: 1)),
                       .clickDrag(button: 1))
        for mapping in [nil, .unchanged, .disabled, .scroll(.down), .key(KeyCombination(keycode: 49))] as [ButtonAction?] {
            XCTAssertEqual(ButtonMappingResolver.planDrag(button: 3, mapping: mapping), .passThrough)
        }
        XCTAssertEqual(ButtonMappingResolver.planDrag(button: 1, mapping: .click(button: 1)),
                       .passThrough)
    }

    func testEveryActionBecomesAPlan() {
        for direction in ScrollDirection.allCases {
            XCTAssertNotEqual(plan(.scroll(direction), button: 3, down: true), .passThrough)
        }
        for system in SystemAction.allCases {
            XCTAssertEqual(plan(.system(system), button: 3, down: true), .execute(.system(system)))
        }
    }

    func testConfigurationRoundTripKeepsActionsAndModifiers() throws {
        let mappings: [Int: ButtonAction] = [
            3: .disabled,
            4: .click(button: 2),
            5: .scroll(.down),
            6: .key(KeyCombination(keycode: 36, modifiers: [.command, .shift])),
            7: .system(.playPause)
        ]
        let data = try JSONEncoder().encode(mappings)
        let decoded = try JSONDecoder().decode([Int: ButtonAction].self, from: data)
        XCTAssertEqual(decoded, mappings)
    }

    func testLegacyKeyConfigurationDecodesAsTap() throws {
        // Pre-behavior JSON carries no behavior field; it must decode as tap.
        let json = #"{"keycode":48,"modifiers":[16]}"#
        let combination = try JSONDecoder().decode(KeyCombination.self, from: Data(json.utf8))
        XCTAssertEqual(combination.keycode, 48)
        XCTAssertEqual(combination.modifiers, [.command])
        XCTAssertEqual(combination.effectiveBehavior, .tap)
    }

    func testKeyHoldBehaviorPairsPressAndRelease() {
        let hold = KeyCombination(keycode: 48, modifiers: [.command], behavior: .hold)
        XCTAssertEqual(plan(.key(hold), button: 4, down: true), .pressKey(hold))
        XCTAssertEqual(plan(.key(hold), button: 4, down: false), .releaseKey(hold))
        let tap = KeyCombination(keycode: 48, modifiers: [.command])
        XCTAssertEqual(plan(.key(tap), button: 4, down: true), .execute(.key(tap)))
        XCTAssertEqual(plan(.key(tap), button: 4, down: false), .suppress)
        let tapExplicit = KeyCombination(keycode: 48, modifiers: [.command], behavior: .tap)
        XCTAssertEqual(plan(.key(tapExplicit), button: 4, down: true), .execute(.key(tapExplicit)))
    }
}
