import AppKit
import ApplicationServices
import FluidMouseCore
import FluidMouseEvents

/// Performs button actions. Runs on the main run loop, where the tap callbacks live.
final class ButtonActionExecutor {
    private let keyboardFactory = KeyboardEventFactory()
    private let buttonFactory = MouseButtonEventFactory()
    private weak var scrollService: ScrollService?

    init(scrollService: ScrollService) { self.scrollService = scrollService }

    var isAvailable: Bool { keyboardFactory.isAvailable && buttonFactory.isAvailable }

    func execute(_ action: ButtonAction, restoringPhysicalFlags: CGEventFlags = []) {
        switch action {
        case .unchanged, .disabled, .click:
            break
        case .scroll(let direction):
            // Negative deltas scroll down; an absolute amount against user preferences.
            scrollService?.injectExternalScroll(y: direction == .down ? -Self.pixelsPerClick : Self.pixelsPerClick)
        case .key(let combination):
            if combination.effectiveBehavior == .hold {
                pressHeldKey(combination)
            } else {
                tapKey(keycode: combination.keycode,
                       modifiers: KeyboardEventFactory.flags(combination.modifiers),
                       restoringPhysicalFlags: restoringPhysicalFlags)
            }
        case .system(let action):
            performSystemAction(action, restoringPhysicalFlags: restoringPhysicalFlags)
        }
    }

    /// Posts a click or drag in place of the original button press.
    func sendClick(button: Int, down: Bool) {
        buttonFactory.makeEvent(button: button, down: down, flags: [])?.post(tap: .cgSessionEventTap)
    }

    func sendDrag(button: Int) {
        buttonFactory.makeDraggedEvent(button: button, flags: [])?.post(tap: .cgSessionEventTap)
    }

    /// Enter hold state: modifiers then key go down and stay until releaseHeldKey.
    func pressHeldKey(_ combination: KeyCombination) {
        let flags = KeyboardEventFactory.flags(combination.modifiers)
        walkModifiers(flags, down: true)
        keyboardFactory.makeEvent(keycode: combination.keycode, down: true, flags: flags)?
            .post(tap: .cgSessionEventTap)
    }

    func releaseHeldKey(_ combination: KeyCombination) {
        let flags = KeyboardEventFactory.flags(combination.modifiers)
        keyboardFactory.makeEvent(keycode: combination.keycode, down: false, flags: flags)?
            .post(tap: .cgSessionEventTap)
        walkModifiers(flags, down: false)
    }

    private func tapKey(keycode: Int, modifiers: CGEventFlags, restoringPhysicalFlags: CGEventFlags) {
        walkModifiers(modifiers, down: true)
        for down in [true, false] {
            keyboardFactory.makeEvent(keycode: keycode, down: down, flags: modifiers)?
                .post(tap: .cgSessionEventTap)
        }
        walkModifiers(modifiers, down: false)
        restorePhysicalModifiers(restoringPhysicalFlags)
    }

    private func walkModifiers(_ targets: CGEventFlags, down: Bool) {
        if down {
            var accumulated = CGEventFlags()
            for modifier in Self.modifierTable where targets.contains(modifier.flag) {
                accumulated.insert(modifier.flag)
                keyboardFactory.makeFlagsChangedEvent(keycode: modifier.keycode, down: true, flags: accumulated)?
                    .post(tap: .cgSessionEventTap)
            }
        } else {
            var accumulated = targets
            for modifier in Self.modifierTable.reversed() where targets.contains(modifier.flag) {
                accumulated.remove(modifier.flag)
                keyboardFactory.makeFlagsChangedEvent(keycode: modifier.keycode, down: false, flags: accumulated)?
                    .post(tap: .cgSessionEventTap)
            }
        }
    }

    /// Re-announces modifiers the user physically holds before the click, so the
    /// kernel state matches the keyboard again after the release bookends.
    private func restorePhysicalModifiers(_ physicalFlags: CGEventFlags) {
        let relevant = physicalFlags.intersection(Self.genericParts)
        guard !relevant.isEmpty else { return }
        walkModifiers(relevant, down: true)
    }

    private func performSystemAction(_ action: SystemAction, restoringPhysicalFlags: CGEventFlags) {
        func combo(_ keycode: Int, _ modifiers: CGEventFlags) {
            tapKey(keycode: keycode, modifiers: modifiers, restoringPhysicalFlags: restoringPhysicalFlags)
        }
        switch action {
        case .missionControl: combo(126, [.maskControl])
        case .appExpose: combo(125, [.maskControl])
        case .showDesktop: combo(103, [])
        case .spotlight: combo(49, [.maskCommand])
        case .launchpad:
            let path = "/System/Applications/Launchpad.app"
            if FileManager.default.fileExists(atPath: path) {
                _ = NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } else {
                combo(118, [])
            }
        case .spaceLeft: combo(123, [.maskControl])
        case .spaceRight: combo(124, [.maskControl])
        case .volumeUp: combo(72, [])
        case .volumeDown: combo(73, [])
        case .mute: combo(74, [])
        case .playPause: sendNXKey(20)
        case .nextTrack: sendNXKey(21)
        case .previousTrack: sendNXKey(22)
        case .brightnessUp: sendNXKey(2)
        case .brightnessDown: sendNXKey(3)
        }
    }

    private static let genericParts: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    /// mach: kVK_Shift 56, kVK_Control 59, kVK_Option 58, kVK_Command 55.
    private static let modifierTable: [(modifier: KeystrokeModifier, flag: CGEventFlags, keycode: Int)] = [
        (.shift, .maskShift, 56),
        (.control, .maskControl, 59),
        (.option, .maskAlternate, 58),
        (.command, .maskCommand, 55)
    ]

    /// Media and brightness keys travel as auxiliary system-defined events:
    /// subtype 8, data1 high half key type and 0xA/0xB for the state.
    private func sendNXKey(_ keyType: Int) {
        for down in [true, false] {
            let state = down ? 0x0A : 0x0B
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: (keyType << 16) | (state << 8), data2: -1),
                let cgEvent = event.cgEvent else { continue }
            cgEvent.setIntegerValueField(.eventSourceUserData, value: ScrollEventFactory.marker)
            cgEvent.post(tap: .cgSessionEventTap)
        }
    }

    private static let pixelsPerClick = 300.0
}
