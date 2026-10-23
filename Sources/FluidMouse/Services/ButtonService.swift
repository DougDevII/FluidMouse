import ApplicationServices
import FluidMouseCore
import FluidMouseEvents

/// Remaps mouse buttons. Sits on a tap at the HID level, earlier than the
/// smoothing tap, so swallowing here removes the event for the whole system.
/// The tap runs independently of the smoothing toggle: mapped buttons and the
/// smooth wheel coexist or work separately.
final class ButtonService {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let executor: ButtonActionExecutor
    /// Source button number to target button number for click remaps being held.
    private var heldClicks: [Int: Int] = [:]
    /// Source button number to the key combination being held while the button stays down.
    private var heldKeys: [Int: KeyCombination] = [:]
    private var captureHandler: ((Int) -> Void)?
    private var suppressUpButton: Int?

    var mappings: [Int: ButtonAction] = [:] { didSet { refreshTap(knownTrusted: nil) } }

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    init(scrollService: ScrollService) { executor = ButtonActionExecutor(scrollService: scrollService) }

    /// Arms the press-to-identify flow: the next physical press is reported and
    /// swallowed, and the matching release is suppressed so nothing clicks.
    func beginCapture(_ handler: @escaping (Int) -> Void) {
        captureHandler = handler
        refreshTap(knownTrusted: nil)
    }

    func endCapture() {
        captureHandler = nil
        // Teardown happens outside the tap callback.
        DispatchQueue.main.async { [weak self] in self?.refreshTap(knownTrusted: nil) }
    }

    /// Installs or removes the tap. Safe to call repeatedly with the same inputs.
    func refreshTap(knownTrusted: Bool?) {
        let trusted = knownTrusted ?? AXIsProcessTrusted()
        let meaningful = mappings.values.contains { $0 != .unchanged } || captureHandler != nil
        guard trusted, meaningful, executor.isAvailable else { stop(); return }
        guard tap == nil else { return }
        let mask = [CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let newTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<ButtonService>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        guard let loop = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap); return
        }
        tap = newTap; runLoopSource = loop
        CFRunLoopAddSource(CFRunLoopGetMain(), loop, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
    }

    func stop() {
        heldClicks.removeAll()
        heldKeys.removeAll()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    }

    private func passThrough(_ event: CGEvent) -> Unmanaged<CGEvent> { Unmanaged.passUnretained(event) }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, AXIsProcessTrusted() { CGEvent.tapEnable(tap: tap, enable: true) }
            return passThrough(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == ScrollService.marker {
            return passThrough(event)
        }
        if let suppress = suppressUpButton,
           [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type),
           Int(event.getIntegerValueField(.mouseEventButtonNumber)) == suppress {
            suppressUpButton = nil
            return nil
        }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            if let captureHandler {
                suppressUpButton = Int(event.getIntegerValueField(.mouseEventButtonNumber))
                endCapture()
                captureHandler(Int(event.getIntegerValueField(.mouseEventButtonNumber)))
                return nil
            }
        }
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            return intercept(button: button, down: true, event: event)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            return intercept(button: button, down: false, event: event)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            guard case .clickDrag(let target) = ButtonMappingResolver.planDrag(
                    button: button, mapping: mappings[button]),
                  heldClicks[button] == target else { return passThrough(event) }
            executor.sendDrag(button: target)
            return nil
        default:
            return passThrough(event)
        }
    }

    private func intercept(button: Int, down: Bool, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Events injected by other applications bypass remapping, so automations
        // and drivers keep their meaning.
        let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
        if pid > 0, pid != Int64(ProcessInfo.processInfo.processIdentifier) {
            return passThrough(event)
        }
        switch ButtonMappingResolver.plan(button: button, down: down, mapping: mappings[button]) {
        case .passThrough:
            return passThrough(event)
        case .suppress:
            return nil
        case .clickDown(let target):
            heldClicks[button] = target
            executor.sendClick(button: target, down: true)
            return nil
        case .clickUp(let target):
            guard heldClicks.removeValue(forKey: button) != nil else { return passThrough(event) }
            executor.sendClick(button: target, down: false)
            return nil
        case .clickDrag:
            return passThrough(event)
        case .execute(let action):
            executor.execute(action, restoringPhysicalFlags: event.flags)
            return nil
        case .pressKey(let combination):
            heldKeys[button] = combination
            executor.pressHeldKey(combination)
            return nil
        case .releaseKey(let combination):
            guard heldKeys.removeValue(forKey: button) != nil else { return passThrough(event) }
            executor.releaseHeldKey(combination)
            return nil
        }
    }
}
