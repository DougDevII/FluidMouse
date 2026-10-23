import CoreGraphics
import FluidMouseCore

/// Builds keyboard events without posting them.
public final class KeyboardEventFactory {
    let source: CGEventSource?
    public var isAvailable: Bool { source != nil }

    public init() {
        source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
    }

    public func makeEvent(keycode: Int, down: Bool, flags: CGEventFlags) -> CGEvent? {
        guard let source,
              let event = CGEvent(keyboardEventSource: source,
                virtualKey: CGKeyCode(keycode), keyDown: down) else { return nil }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: ScrollEventFactory.marker)
        return event
    }

    /// Modifier press/release that mirrors a physical keyboard. Without these
    /// the kernel's modifier state stays "held" after any event whose flags
    /// field carries a modifier.
    public func makeFlagsChangedEvent(keycode: Int, down: Bool, flags: CGEventFlags) -> CGEvent? {
        guard let event = makeEvent(keycode: keycode, down: down, flags: flags) else { return nil }
        event.type = .flagsChanged
        return event
    }

    /// CGEventFlags for the package-independent modifier set.
    public static func flags(_ modifiers: Set<KeystrokeModifier>) -> CGEventFlags {
        var flags = CGEventFlags()
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }
}
