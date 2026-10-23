import CoreGraphics

/// Builds button clicks and drags without posting them. Synthetic events carry
/// the shared marker so the app's taps pass them through untouched.
public final class MouseButtonEventFactory {
    public static let marker = ScrollEventFactory.marker
    let source: CGEventSource?
    private let cursorLocation: () -> CGPoint?
    public var isAvailable: Bool { source != nil }

    public init(cursorLocation: @escaping () -> CGPoint? = { CGEvent(source: nil)?.location }) {
        self.cursorLocation = cursorLocation
        source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
        let allowHardware: CGEventFilterMask = [.permitLocalMouseEvents,
            .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        source?.setLocalEventsFilterDuringSuppressionState(allowHardware,
            state: .eventSuppressionStateSuppressionInterval)
        source?.setLocalEventsFilterDuringSuppressionState(allowHardware,
            state: .eventSuppressionStateRemoteMouseDrag)
    }

    /// Button numbering follows `mouseEventButtonNumber`: 0 left, 1 right, 2 middle, extras from 3.
    public func makeEvent(button: Int, down: Bool, flags: CGEventFlags) -> CGEvent? {
        guard let source, let location = cursorLocation(),
              location.x.isFinite, location.y.isFinite else { return nil }
        guard let event = CGEvent(mouseEventSource: source,
            mouseType: down ? Self.downType(button: button) : Self.upType(button: button),
            mouseCursorPosition: location, mouseButton: Self.cgButton(button)) else { return nil }
        event.flags = flags
        event.location = location
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        return event
    }

    public func makeDraggedEvent(button: Int, flags: CGEventFlags) -> CGEvent? {
        guard let source, let location = cursorLocation(),
              location.x.isFinite, location.y.isFinite else { return nil }
        guard let event = CGEvent(mouseEventSource: source,
            mouseType: Self.draggedType(button: button), mouseCursorPosition: location,
            mouseButton: Self.cgButton(button)) else { return nil }
        event.flags = flags
        event.location = location
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        return event
    }

    public static func downType(button: Int) -> CGEventType {
        switch button {
        case 0: return .leftMouseDown
        case 1: return .rightMouseDown
        default: return .otherMouseDown
        }
    }

    public static func upType(button: Int) -> CGEventType {
        switch button {
        case 0: return .leftMouseUp
        case 1: return .rightMouseUp
        default: return .otherMouseUp
        }
    }

    public static func draggedType(button: Int) -> CGEventType {
        switch button {
        case 0: return .leftMouseDragged
        case 1: return .rightMouseDragged
        default: return .otherMouseDragged
        }
    }

    private static func cgButton(_ button: Int) -> CGMouseButton {
        switch button {
        case 0: return .left
        case 1: return .right
        default: return .center
        }
    }
}
