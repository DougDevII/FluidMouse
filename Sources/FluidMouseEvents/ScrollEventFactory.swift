import CoreGraphics

/// Constructs scrolling events without posting them. Query the live Quartz
/// cursor for every frame; never replay the location from the original tick.
public final class ScrollEventFactory {
    public static let marker: Int64 = 0x464C5549444F
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

    public func makeEvent(x: Int32, y: Int32, flags: CGEventFlags) -> CGEvent? {
        guard let source, let location = cursorLocation(),
              location.x.isFinite, location.y.isFinite,
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0) else { return nil }
        event.flags = flags
        event.location = location
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        return event
    }
}
