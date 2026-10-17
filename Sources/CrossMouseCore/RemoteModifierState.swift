import CoreGraphics

/// The keys this input lease actually sent DOWN. flagsChanged is a state
/// snapshot, not a toggle. Reconcile before every forwarded key/mouse event so
/// a missed flagsChanged UP cannot poison the following paste/click/shortcut.
/// No global keyboard mapping or operating-system key state is changed here.
public struct RemoteModifierState {
    private var pressed = Set<Int>()
    private var capsOn = false
    public init() {}

    /// Receiver acquisition/leave already releases its owned input. Reset our
    /// ledger at that same boundary; never reuse another lease's pressed bits.
    public mutating func reset(flags: CGEventFlags = []) {
        pressed.removeAll()
        capsOn = flags.contains(.maskAlphaShift)
    }

    public mutating func update(flags: CGEventFlags,
                                sideKeyState: ((Int) -> Bool)? = nil) -> [CrossMouseMessage] {
        let desired = Self.heldKeys(flags: flags, sideKeyState: sideKeyState)
        var result = pressed.subtracting(desired).sorted().map {
            CrossMouseMessage(type: "key", down: false, code: $0)
        }
        result += desired.subtracting(pressed).sorted().map {
            CrossMouseMessage(type: "key", down: true, code: $0)
        }
        pressed = desired
        let nextCaps = flags.contains(.maskAlphaShift)
        if nextCaps != capsOn {
            // Caps is a toggle, not a modifier held down for the entire time
            // its lock flag is enabled. Send a complete press for each change.
            result += [CrossMouseMessage(type: "key", down: true, code: 57),
                       CrossMouseMessage(type: "key", down: false, code: 57)]
        }
        capsOn = nextCaps
        return result
    }

    public static let shortcutFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    public static func handlesKeyCode(_ code: Int) -> Bool { (54...63).contains(code) }

    /// Side-specific masks from Apple's public IOLLEvent.h. Aggregate flags are
    /// checked first, so a stale low bit cannot manufacture a held modifier.
    /// For sources lacking side bits the caller may consult the public CG key
    /// state table. Without a table, aggregate-only synthetic events use left.
    public static func heldKeys(flags: CGEventFlags, sideKeyState: ((Int) -> Bool)? = nil) -> Set<Int> {
        let groups: [(CGEventFlags, Int, UInt64, Int, UInt64)] = [
            (.maskCommand, 55, 0x8, 54, 0x10),
            (.maskControl, 59, 0x1, 62, 0x2000),
            (.maskAlternate, 58, 0x20, 61, 0x40),
            (.maskShift, 56, 0x2, 60, 0x4)
        ]
        var held = Set<Int>()
        for (aggregate, left, leftMask, right, rightMask) in groups where flags.contains(aggregate) {
            if flags.rawValue & (leftMask | rightMask) != 0 {
                if flags.rawValue & leftMask != 0 { held.insert(left) }
                if flags.rawValue & rightMask != 0 { held.insert(right) }
            } else if let sideKeyState {
                if sideKeyState(left) { held.insert(left) }
                if sideKeyState(right) { held.insert(right) }
            } else { held.insert(left) }
        }
        return held
    }
}
