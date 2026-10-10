import AppKit
import CoreGraphics

/// Normalize the two macOS representations of the F8/play key at the actual
/// event-tap boundary. Media events are NX_SYSDEFINED, not keyDown/keyUp.
/// No keyboard mode, OS preference, or unrelated media key is changed.
public struct DisplayReturnEvent {
    public static let systemDefinedType = CGEventType(rawValue: 14)! // NX_SYSDEFINED
    public static let eventMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) |
        (1 << systemDefinedType.rawValue)

    public let source: DisplayReturnShortcut.Source
    public let down: Bool
    public let isRepeat: Bool
    public let hasModifiers: Bool

    public init?(type: CGEventType, event: CGEvent) {
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        hasModifiers = !event.flags.intersection(modifiers).isEmpty
        if type == .keyDown || type == .keyUp {
            guard event.getIntegerValueField(.keyboardEventKeycode) == DisplayReturnShortcut.keyCode
            else { return nil }
            source = .functionF8
            down = type == .keyDown
            isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        } else if type == Self.systemDefinedType,
                  let special = NSEvent(cgEvent: event), special.subtype.rawValue == 8 {
            // NX_SUBTYPE_AUX_CONTROL_BUTTONS / NX_KEYTYPE_PLAY from IOKit headers.
            let data = UInt32(truncatingIfNeeded: special.data1)
            guard (data >> 16) & 0xffff == 16 else { return nil }
            let state = (data >> 8) & 0xff
            guard state == 0x0a || state == 0x0b else { return nil }
            source = .playPause
            down = state == 0x0a
            isRepeat = data & 1 != 0
        } else {
            return nil
        }
    }

    public func apply(to shortcut: inout DisplayReturnShortcut, enabled: Bool)
        -> DisplayReturnShortcut.Decision {
        shortcut.handle(source: source, down: down, isRepeat: isRepeat,
                        hasModifiers: hasModifiers, enabled: enabled)
    }
}
