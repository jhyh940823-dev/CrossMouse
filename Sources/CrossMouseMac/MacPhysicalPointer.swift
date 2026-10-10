import Foundation
import CoreGraphics
import IOKit.hid
import CrossMouseCore

/// Relative motion comes from the physical pointing device, not from the
/// desktop coordinates which CrossMouse itself changes during video handoff.
/// Mouse-only, non-exclusive observer: never captures keyboard or clipboard.
@MainActor
final class MacPhysicalPointer {
    private var manager: IOHIDManager?
    private var capture = PhysicalMotionCapture()
    private var observedRelativeMotion = false
    var onMotion: ((Int, Int) -> Void)?

    func start() {
        guard manager == nil else { return }
        let value = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(value, [
            [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 2],
            [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 1]
        ] as CFArray)
        IOHIDManagerRegisterInputValueCallback(value, physicalPointerValue,
            Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(value, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(value, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(value, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return
        }
        manager = value
    }
    var canCapture: Bool {
        guard observedRelativeMotion, let manager,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return false }
        return devices.contains { device in
            guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone))
                    as? [IOHIDElement] else { return false }
            let axes = Set(elements.filter { IOHIDElementIsRelative($0) && IOHIDElementGetUsagePage($0) == 1 }
                .map { IOHIDElementGetUsage($0) })
            return axes.contains(0x30) && axes.contains(0x31)
        }
    }
    func beginCapture() { capture.begin(at: mach_absolute_time()) }
    func endCapture() { capture.end() }
    func stop() {
        capture.end()
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }
    fileprivate func receive(axis: UInt32, amount: Int, timestamp: UInt64) {
        guard amount != 0, axis == 0x30 || axis == 0x31 else { return }
        observedRelativeMotion = true
        guard capture.accepts(reportTimestamp: timestamp) else { return }
        switch axis {
        case 0x30: onMotion?(amount, 0)
        case 0x31: onMotion?(0, amount)
        default: break
        }
    }
}

private let physicalPointerValue: IOHIDValueCallback = { context, result, _, value in
    guard let context, result == kIOReturnSuccess else { return }
    let owner = Unmanaged<MacPhysicalPointer>.fromOpaque(context).takeUnretainedValue()
    let element = IOHIDValueGetElement(value)
    guard IOHIDElementIsRelative(element), IOHIDElementGetUsagePage(element) == 1 else { return }
    let axis = IOHIDElementGetUsage(element)
    let amount = max(-32768, min(32768, IOHIDValueGetIntegerValue(value)))
    let timestamp = IOHIDValueGetTimeStamp(value)
    MainActor.assumeIsolated {
        owner.receive(axis: axis, amount: amount, timestamp: timestamp)
    }
}
