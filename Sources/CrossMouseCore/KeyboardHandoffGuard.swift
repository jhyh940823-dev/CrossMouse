import CoreGraphics

/// A delayed edge callback must not acquire Windows after the user has started
/// another local key/chord/click. Its revision carries intent, not elapsed time.
public struct KeyboardHandoffGuard {
    // The combined session table includes synthesized/intercepted input and
    // can retain a key that physical hardware has already released.
    public static let acquisitionSource = CGEventSourceStateID.hidSystemState
    public private(set) var revision: UInt64 = 0
    public init() {}
    public func isCurrent(_ requestedRevision: UInt64) -> Bool { revision == requestedRevision }
    public mutating func invalidate() { revision &+= 1 }
    @discardableResult
    public mutating func observeLocal(_ type: CGEventType) -> Bool {
        switch type {
        case .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            invalidate(); return true
        default: return false
        }
    }
    public static func awaitsWindowsInput(_ phase: AutomaticHandoff.Phase) -> Bool {
        switch phase {
        case .preparing, .switchingToWindows, .acquiring: true
        case .local, .windows, .switchingToMac: false
        }
    }
    public static func canAcquire(flags: CGEventFlags, buttonsDown: Bool,
                                  keyDown: (CGKeyCode) -> Bool) -> Bool {
        guard flags.intersection(RemoteModifierState.shortcutFlags).isEmpty, !buttonsDown else { return false }
        // Caps/Fn are not held shortcut keys. Consult only momentary state at
        // acquisition; never log keycodes, reconstruct text or poll in a timer.
        return !(0..<128).contains { code in
            code != 57 && code != 63 && keyDown(CGKeyCode(code))
        }
    }
}
