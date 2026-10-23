import Foundation
import IOKit
import IOKit.hid

/// Recognizes connected mice through the public IOHIDManager and keeps the
/// list current as devices come and go. Mirrors the device listing LinearMouse
/// builds from the private IOHIDEventSystemClient, using only public entries.
final class DeviceService {
    /// Identity shown in the UI, in the "%@ (VID=0x…, PID=0x…)" format LinearMouse uses.
    struct DeviceInfo: Equatable {
        var name: String
        var vendorID: Int?
        var productID: Int?
        var transport: String?

        var display: String {
            var text = name
            if let vendorID, let productID {
                text += String(format: " (VID=0x%04X, PID=0x%04X)", vendorID, productID)
            } else if let vendorID {
                text += String(format: " (VID=0x%04X)", vendorID)
            }
            return text
        }
    }

    private var manager: IOHIDManager?
    private(set) var devices: [DeviceInfo] = []
    var onChange: (() -> Void)?

    func start() {
        guard manager == nil else { return }
        let newManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(0))
        let matching: [String: NSNumber] = [
            kIOHIDDeviceUsagePageKey: NSNumber(value: kHIDPage_GenericDesktop),
            kIOHIDDeviceUsageKey: NSNumber(value: kHIDUsage_GD_Mouse)
        ]
        IOHIDManagerSetDeviceMatching(newManager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(newManager, { context, _, _, _ in
            DeviceService.dispatch(context)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(newManager, { context, _, _, _ in
            DeviceService.dispatch(context)
        }, context)
        IOHIDManagerScheduleWithRunLoop(newManager, CFRunLoopGetMain(), "kCFRunLoopDefaultMode" as CFString)
        IOHIDManagerOpen(newManager, IOOptionBits(0))
        manager = newManager
        refresh()
    }

    func stop() {
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(0))
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), "kCFRunLoopDefaultMode" as CFString)
        }
        manager = nil
        devices = []
        onChange?()
    }

    private static func dispatch(_ context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        DispatchQueue.main.async {
            Unmanaged<DeviceService>.fromOpaque(context).takeUnretainedValue().refresh()
        }
    }

    func refresh() {
        guard let manager,
              let services = IOHIDManagerCopyDevices(manager) else { return }
        let count = CFSetGetCount(services)
        var refs = [UnsafeRawPointer?](repeating: nil, count: count)
        CFSetGetValues(services, &refs)
        var info: [DeviceInfo] = []
        for ref in refs.compactMap({ $0 }) {
            let device = unsafeBitCast(ref, to: IOHIDDevice.self)
            info.append(readDevice(device))
        }
        devices = info.sorted { $0.name < $1.name }
        onChange?()
    }

    private func readDevice(_ device: IOHIDDevice) -> DeviceInfo {
        DeviceInfo(
            name: Self.string(device, kIOHIDProductKey) ?? "Mouse",
            vendorID: Self.number(device, kIOHIDVendorIDKey),
            productID: Self.number(device, kIOHIDProductIDKey),
            transport: Self.string(device, kIOHIDTransportKey))
    }

    private static func string(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func number(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }
}
