import AppKit
import ApplicationServices
import FluidMouseCore
import FluidMouseEvents

final class ScrollService {
    static let marker = ScrollEventFactory.marker
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var timer: Timer?
    private var engine = ScrollEngine()
    private let eventFactory = ScrollEventFactory()
    private var lastFrame = 0.0
    private var anchor = NSPoint.zero
    private var flags = CGEventFlags()
    var speed = 2.0
    var smoothness = 0.5
    var reverse = false
    private(set) var wheels = 0
    private(set) var passedContinuous = 0
    private(set) var frames = 0
    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() -> Bool {
        if isRunning { return true }
        stop()
        guard AXIsProcessTrusted(), eventFactory.isAvailable else { return false }
        let mask = [CGEventType.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<ScrollService>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let loop = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap); return false
        }
        tap = newTap; runLoopSource = loop
        CFRunLoopAddSource(CFRunLoopGetMain(), loop, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        return isRunning
    }

    func stop() {
        cancel()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil; runLoopSource = nil
    }

    func cancel() { timer?.invalidate(); timer = nil; engine.cancel() }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancel()
            if let tap, AXIsProcessTrusted() { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker {
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { cancel(); return Unmanaged.passUnretained(event) }
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        let permitted = ScrollPolicy.shouldSmooth(enabled: isRunning, continuous: continuous,
            phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentum: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            modified: !event.flags.intersection(modifiers).isEmpty, ownEvent: false)
        guard permitted else {
            if continuous { passedContinuous += 1 }
            cancel(); return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.scrollWheelEventDeltaAxis3) != 0 {
            cancel(); return Unmanaged.passUnretained(event)
        }
        let dy = ScrollPolicy.pixelDistance(points: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
            lines: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        let dx = ScrollPolicy.pixelDistance(points: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
            lines: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        guard dx != 0 || dy != 0 else { return Unmanaged.passUnretained(event) }
        if timer != nil && (event.flags != flags || movedAway()) { cancel() }
        flags = event.flags; anchor = NSEvent.mouseLocation
        let gain = speed * (reverse ? -1 : 1)
        engine.add(x: dx * gain, y: dy * gain)
        wheels += 1
        ensureTimer()
        return nil
    }

    /// Adds an absolute scroll amount in pixels. Button actions mean the direction
    /// they name, so user speed, direction inversion and wheel gain do not apply.
    func injectExternalScroll(y amount: Double) {
        let clamped = min(1_600, max(-1_600, amount))
        guard isRunning, eventFactory.isAvailable else {
            guard let event = eventFactory.makeEvent(x: 0, y: Int32(clamped), flags: []) else { return }
            event.post(tap: .cgSessionEventTap)
            frames += 1
            return
        }
        anchor = NSEvent.mouseLocation
        engine.add(x: 0, y: clamped)
        ensureTimer()
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        lastFrame = ProcessInfo.processInfo.systemUptime
        let fps = min(120, max(60, NSScreen.main?.maximumFramesPerSecond ?? 60))
        let frameTimer = Timer(timeInterval: 1 / Double(fps), repeats: true) { [weak self] _ in self?.advance() }
        frameTimer.tolerance = 0.001
        timer = frameTimer
        RunLoop.main.add(frameTimer, forMode: .common)
    }

    private func movedAway() -> Bool {
        let point = NSEvent.mouseLocation
        return hypot(point.x - anchor.x, point.y - anchor.y) > 12
    }

    private func advance() {
        guard isRunning, !movedAway(),
              NSEvent.modifierFlags.intersection([.control, .option, .command]).isEmpty else { cancel(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let frame = engine.step(elapsed: now - lastFrame, timeConstant: 0.025 + smoothness * 0.11)
        lastFrame = now
        if frame.x != 0 || frame.y != 0 {
            guard let event = eventFactory.makeEvent(x: frame.x, y: frame.y, flags: flags)
                else { cancel(); return }
            event.post(tap: .cgSessionEventTap)
            frames += 1
        }
        if !engine.isAnimating { timer?.invalidate(); timer = nil }
    }
}
